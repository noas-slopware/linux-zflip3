#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pack a kernel + initramfs + dtb into a Samsung boot or recovery image.
#
# The header fields come from the stock image's own mkbootimg arguments (written by
# tools/extract-firmware.sh to out/boot/mkbootimg_args), because ABL matches on the
# board string and the offsets. The ASCII trailer "SEANDROIDENFORCE" is appended the
# same way LineageOS and postmarketOS do for Samsung devices; without it ABL
# reports a bogus SEAndroid state.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
load_sources

usage() {
  cat <<'EOF'
usage: bootimg.sh --kernel Image --out IMG [options]

  --kernel PATH        kernel Image (required)
  --ramdisk PATH       initramfs cpio (optional but you want one)
  --dtb PATH           device tree blob (optional if the stock image has none)
  --cmdline STRING     override the kernel command line
  --board STRING       override the board string
  --stock-args PATH    mkbootimg args from the stock image
                       (default: out/boot/mkbootimg_args)
  --out PATH           output image (required)
  --no-trailer         do not append SEANDROIDENFORCE (you almost never want this)
  --print-args         print the mkbootimg invocation and exit
EOF
}

KERNEL=""; RAMDISK=""; DTB=""; CMDLINE=""; BOARD=""
ARGS_FILE="$REPO_ROOT/out/boot/mkbootimg_args"
OUT=""; TRAILER=1; PRINT=0

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
    --no-trailer) TRAILER=0; shift ;;
    --print-args) PRINT=1; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$KERNEL" ] || { usage >&2; exit 1; }
[ -n "$OUT" ] || { usage >&2; exit 1; }
[ -f "$KERNEL" ] || die "no such kernel: $KERNEL"
[ -n "$DTB" ] || die "b2q boots with header v2, which requires --dtb; ABL needs the device tree in the boot image"
[ -f "$DTB" ] || die "no such dtb: $DTB"
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
      --kernel|--ramdisk|--dtb|--recovery_dtbo|--recovery_acpio|--cmdline) shift 2 ;;
      *) args+=("$1"); shift ;;
    esac
  done
else
  warn "no stock args at $ARGS_FILE; falling back to b2q header v2 defaults"
  args=(--header_version 2 --pagesize 4096
        --kernel_offset 0x00008000 --ramdisk_offset 0x02000000
        --tags_offset 0x01e00000 --dtb_offset 0x01f00000)
fi

[ -n "$BOARD" ] && args+=(--board "$BOARD")
[ -n "$CMDLINE" ] && args+=(--cmdline "$CMDLINE")

cmd=(mkbootimg "${args[@]}" --kernel "$KERNEL" -o "$OUT")
[ -n "$RAMDISK" ] && cmd+=(--ramdisk "$RAMDISK")
[ -n "$DTB" ] && cmd+=(--dtb "$DTB")

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
  die "image is larger than the $B2Q_BOOT_PART_SIZE byte boot partition"
fi
if [ "$size" -gt $((B2Q_BOOT_PART_SIZE * 95 / 100)) ]; then
  warn "image is within 5% of the partition size; trim the initramfs"
fi
