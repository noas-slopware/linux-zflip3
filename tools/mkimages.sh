#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pack the images the phone boots from.
#
#   boot.img     U-Boot for the boot partition: header v0, gzip'd u-boot-nodtb.bin with
#                the b2q dtb appended. ABL takes the appended dtb (dtbo is empty) and
#                hands it to U-Boot, which runs on it.
#   linux.img    Linux for the recovery partition, which U-Boot reads from UFS and boots:
#                header v2 with Image.gz, the initramfs, the dtb and the command line
#                from configs/cmdline. U-Boot fixes up memory in the dtb it passes on.
#   dtbo-empty.img  24 MiB of zeros for dtbo, so ABL applies no Samsung overlay.
#
# linux.img is also what "fastboot boot" takes when U-Boot sits in fastboot.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
load_sources

usage() {
  cat <<'EOF'
usage: mkimages.sh [options]

  --tree DIR       kernel tree (default: .cache/linux-$LINUX_VERSION)
  --u-boot FILE    u-boot-nodtb.bin (default: .cache/u-boot/build/u-boot-nodtb.bin)
  --ramdisk PATH   initramfs (default: out/initramfs.cpio.gz)
  --cmdline FILE   kernel command line (default: configs/cmdline)
  --out DIR        output directory (default: out)
EOF
}

TREE="$REPO_ROOT/.cache/linux-$LINUX_VERSION"
UBOOT="$REPO_ROOT/.cache/u-boot/build/u-boot-nodtb.bin"
RAMDISK="$REPO_ROOT/out/initramfs.cpio.gz"
CMDFILE="$REPO_ROOT/configs/cmdline"
OUT="$REPO_ROOT/out"

PART_SIZE=$((96 * 1024 * 1024))
DTBO_PART_SIZE=$((24 * 1024 * 1024))

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tree) TREE=${2:?}; shift 2 ;;
    --u-boot) UBOOT=${2:?}; shift 2 ;;
    --ramdisk) RAMDISK=${2:?}; shift 2 ;;
    --cmdline) CMDFILE=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

KERNEL="$TREE/arch/arm64/boot/Image"
DTB="$TREE/arch/arm64/boot/dts/qcom/sm8350-samsung-b2q.dtb"
[ -f "$KERNEL" ] || die "no kernel at $KERNEL (run tools/build-kernel.sh)"
[ -f "$DTB" ] || die "no b2q dtb at $DTB (run tools/build-kernel.sh)"
[ -f "$UBOOT" ] || die "no U-Boot at $UBOOT (run tools/build-u-boot.sh)"
[ -f "$RAMDISK" ] || die "no initramfs at $RAMDISK (run tools/build-initramfs.sh)"
[ -f "$CMDFILE" ] || die "no command line at $CMDFILE"
need mkbootimg gzip sha256sum
mkdir -p "$OUT"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

check() {
  local size
  size=$(stat -c%s "$1")
  [ "$size" -le "$PART_SIZE" ] || die "$1 is larger than the ${PART_SIZE}-byte partition"
  log "$1: $size bytes ($(sha256sum "$1" | cut -d' ' -f1))"
}

gzip -9 -n -c "$UBOOT" > "$WORK/u-boot.gz"
cat "$WORK/u-boot.gz" "$DTB" > "$WORK/u-boot.gz-dtb"
# ABL hands the boot image's OS version and patch level to keymaster64 (and
# through it the secure processor); stock's boot.img carries 11.0.0 / 2026-08.
# Ours had zero. Changing it alone did not change keymaster64's results, but
# stock's values are kept so the secure world sees what it sees on stock. Use
# them exactly, never newer ones: rollback state in the secure processor may
# not come back down.
mkbootimg --header_version 0 --kernel "$WORK/u-boot.gz-dtb" \
  --base 0x00000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --os_version 11.0.0 --os_patch_level 2026-08 \
  --tags_offset 0x00000100 --pagesize 4096 -o "$OUT/boot.img"
check "$OUT/boot.img"

gzip -9 -n -c "$KERNEL" > "$WORK/Image.gz"
mkbootimg --header_version 2 --kernel "$WORK/Image.gz" --ramdisk "$RAMDISK" --dtb "$DTB" \
  --base 0x80000000 --kernel_offset 0x00008000 --ramdisk_offset 0x01000000 \
  --dtb_offset 0x01f00000 --tags_offset 0x00000100 --pagesize 4096 \
  --cmdline "$(tr -d '\n' < "$CMDFILE")" -o "$OUT/linux.img"
check "$OUT/linux.img"

if [ ! -f "$OUT/dtbo-empty.img" ] || [ "$(stat -c%s "$OUT/dtbo-empty.img")" != "$DTBO_PART_SIZE" ]; then
  rm -f "$OUT/dtbo-empty.img"
  truncate -s "$DTBO_PART_SIZE" "$OUT/dtbo-empty.img"
fi
log "$OUT/dtbo-empty.img: $DTBO_PART_SIZE bytes of zeros"

cat <<EOF

From download mode (first install, or a new U-Boot):

  B2Q_UNLOCKED=1 tools/flash.sh --partition dtbo --image $OUT/dtbo-empty.img \\
                                --partition boot --image $OUT/boot.img \\
                                --partition recovery --image $OUT/linux.img

A new kernel without download mode: write $OUT/linux.img to the recovery partition from
Linux and reboot, or "fastboot boot $OUT/linux.img" while U-Boot sits in fastboot.
EOF
