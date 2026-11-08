#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pack a kernel, initramfs and dtb into Samsung boot / recovery / vendor_boot images.
#
# This firmware uses boot header v3 and puts the device tree in the *vendor_boot*
# partition, not in boot.img. So M1 needs two images:
#
#   boot.img         header v3, kernel + our initramfs, no dtb
#   vendor_boot.img  header v3, our dtb + (optionally) a vendor ramdisk
#
# Header fields come from the stock images' own mkbootimg arguments, so the board
# string (SRPUC29A015 on this build) and the offsets are never guessed. boot.img and
# recovery.img get the ASCII trailer SEANDROIDENFORCE, the same way LineageOS and Nura
# do for Samsung devices; vendor_boot does not.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
load_sources

usage() {
  cat <<'EOF'
usage: bootimg.sh (--kernel IMAGE --out IMG | --vendor --dtb DTB --out IMG) [options]

  --kernel PATH        kernel Image (boot and recovery images)
  --ramdisk PATH       initramfs cpio
  --dtb PATH           device tree blob (required for --vendor)
  --vendor             build a vendor_boot image instead of a boot image
  --cmdline STRING     override the command line
  --board STRING       override the board string
  --stock-args PATH    mkbootimg args from the stock image
                       (default: evidence/raw/{boot,vendor_boot}/mkbootimg_args)
  --out PATH           output image (required)
  --trailer / --no-trailer
                       force or suppress the SEANDROIDENFORCE trailer
                       (default: on for boot/recovery, off for vendor_boot)
  --print-args         print the mkbootimg invocation and exit
EOF
}

KERNEL=""; RAMDISK=""; DTB=""; CMDLINE=""; BOARD=""; OUT=""
ARGS_FILE=""; VENDOR=0; TRAILER=""; PRINT=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --kernel) KERNEL=${2:?}; shift 2 ;;
    --ramdisk) RAMDISK=${2:?}; shift 2 ;;
    --dtb) DTB=${2:?}; shift 2 ;;
    --cmdline) CMDLINE=${2:?}; shift 2 ;;
    --board) BOARD=${2:?}; shift 2 ;;
    --stock-args) ARGS_FILE=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --vendor) VENDOR=1; shift ;;
    --trailer) TRAILER=1; shift ;;
    --no-trailer) TRAILER=0; shift ;;
    --print-args) PRINT=1; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$OUT" ] || { usage >&2; exit 1; }
if [ "$VENDOR" = 1 ]; then
  [ -n "$DTB" ] || die "--vendor needs --dtb: that is where ABL reads the device tree on this firmware"
  [ -f "$DTB" ] || die "no such dtb: $DTB"
  ARGS_FILE=${ARGS_FILE:-$REPO_ROOT/evidence/raw/vendor_boot/mkbootimg_args}
  TRAILER=${TRAILER:-0}
else
  [ -n "$KERNEL" ] || { usage >&2; exit 1; }
  [ -f "$KERNEL" ] || die "no such kernel: $KERNEL"
  ARGS_FILE=${ARGS_FILE:-$REPO_ROOT/evidence/raw/boot/mkbootimg_args}
  TRAILER=${TRAILER:-1}
fi
[ -z "$RAMDISK" ] || [ -f "$RAMDISK" ] || die "no such ramdisk: $RAMDISK"
need mkbootimg sha256sum

args=()
if [ -f "$ARGS_FILE" ]; then
  log "using stock header from $ARGS_FILE"
  # unpack_bootimg emits shell-escaped arguments; this is the documented way to reuse them.
  eval "set -- $(cat "$ARGS_FILE")"
  while [ $# -gt 0 ]; do
    case "$1" in
      # drop what we replace, keep everything else verbatim and in order
      --kernel|--ramdisk|--dtb|--cmdline|--vendor_ramdisk|--vendor_cmdline) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
else
  warn "no stock args at $ARGS_FILE; falling back to header v3 defaults"
  args=(--header_version 3 --pagesize 4096
        --kernel_offset 0x00008000 --ramdisk_offset 0x02000000
        --tags_offset 0x01e00000 --dtb_offset 0x01f00000)
fi

[ -n "$BOARD" ] && args+=(--board "$BOARD")
if [ -n "$CMDLINE" ]; then
  if [ "$VENDOR" = 1 ]; then args+=(--vendor_cmdline "$CMDLINE"); else args+=(--cmdline "$CMDLINE"); fi
fi
[ -n "$DTB" ] && args+=(--dtb "$DTB")

if [ "$VENDOR" = 1 ]; then
  # mkbootimg insists on a vendor ramdisk. The stock one holds vendor modules; ours has
  # nothing to put there, and the kernel's initramfs rides in boot.img instead.
  if [ -z "$RAMDISK" ]; then
    empty_dir=$(mktemp -d)
    RAMDISK=$(mktemp)
    ( cd "$empty_dir" && find . | cpio -o -H newc --quiet ) | gzip -9 > "$RAMDISK"
    trap 'rm -rf "$empty_dir" "$RAMDISK"' EXIT
    log "built an empty vendor ramdisk ($(stat -c%s "$RAMDISK") bytes)"
  fi
  cmd=(mkbootimg "${args[@]}" --vendor_boot "$OUT" --vendor_ramdisk "$RAMDISK")
else
  cmd=(mkbootimg "${args[@]}" --kernel "$KERNEL" -o "$OUT")
  [ -n "$RAMDISK" ] && cmd+=(--ramdisk "$RAMDISK")
fi

if [ "$PRINT" = 1 ]; then
  printf '%q ' "${cmd[@]}"; echo
  exit 0
fi

mkdir -p "$(dirname -- "$OUT")"
"${cmd[@]}"
if [ "$TRAILER" = 1 ]; then
  printf 'SEANDROIDENFORCE' >> "$OUT"
fi

size=$(stat -c%s "$OUT")
log "$OUT: $size bytes ($(sha256sum "$OUT" | cut -d' ' -f1))"
if [ "$size" -gt "$B2Q_BOOT_PART_SIZE" ]; then
  die "image is larger than the ${B2Q_BOOT_PART_SIZE}-byte partition"
fi
if [ "$size" -gt $((B2Q_BOOT_PART_SIZE * 95 / 100)) ]; then
  warn "image is within 5% of the partition size; trim the ramdisk"
fi
