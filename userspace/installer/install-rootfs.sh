#!/bin/sh
# SPDX-License-Identifier: MIT
# M3.5: wipe Android and put an Arch rootfs on the internal UFS.
#
# Runs ON THE PHONE, from the rescue/installer initramfs, as root. There is no GPT
# surgery here on purpose: `super` (12 GB) becomes / and `userdata` becomes /home,
# both formatted in place. The partition table, `persist`, `efs`, `param` and the
# modem partitions are never touched.
#
# DESTRUCTIVE. Dry run unless --yes-wipe is given.

set -eu

ROOT_PART=/dev/disk/by-partlabel/super
HOME_PART=/dev/disk/by-partlabel/userdata
MOUNT=/newroot
DRY=1
ROOTFS=""
BOOTIMG=""
STREAM_PORT=""

usage() {
  cat <<'EOF'
usage: install-rootfs.sh --rootfs PATH --boot PATH [options]

  --rootfs PATH     tar of the Arch rootfs (uncompressed or .tar.zst)
  --boot PATH       boot.img built by tools/bootimg.sh
  --yes-wipe        actually format super and userdata
  --stream PORT     read the rootfs tar from this TCP port instead of --rootfs
                    (host side: nc <phone-ip> PORT < rootfs.tar)
  --mount DIR       mount point (default /newroot)

Run this from the installer initramfs, with the internal storage idle. Nothing from
Android survives. The stock firmware tar on your PC is the only way back.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --rootfs) ROOTFS=${2:?}; shift 2 ;;
    --boot) BOOTIMG=${2:?}; shift 2 ;;
    --yes-wipe) DRY=0; shift ;;
    --stream) STREAM_PORT=${2:?}; shift 2 ;;
    --mount) MOUNT=${2:?}; shift 2 ;;
    *) echo "error: unknown option: $1" >&2; exit 1 ;;
  esac
done

[ -f "$BOOTIMG" ] || { echo "error: --boot is required" >&2; exit 1; }
[ -n "$ROOTFS" ] || [ -n "$STREAM_PORT" ] || { echo "error: give --rootfs or --stream" >&2; exit 1; }

echo "root: $ROOT_PART -> $MOUNT"
echo "home: $HOME_PART -> $MOUNT/home"
echo "boot: $BOOTIMG"
if [ "$DRY" = 1 ]; then
  echo
  echo "DRY RUN. This would mkfs.ext4 both partitions and destroy Android."
  [ -e "$ROOT_PART" ] || echo "(Note: $ROOT_PART does not exist here: not on the phone.)"
  echo "Re-run with --yes-wipe when that is what you want."
  exit 0
fi

[ -e "$ROOT_PART" ] || { echo "error: no $ROOT_PART; not on the phone?" >&2; exit 1; }

echo
echo "Wiping Android in 10 seconds. Ctrl-C to stop."
sleep 10

mkfs.ext4 -F -L b2q-root "$ROOT_PART"
mkfs.ext4 -F -L b2q-home "$HOME_PART"

mkdir -p "$MOUNT"
mount "$ROOT_PART" "$MOUNT"
mkdir -p "$MOUNT/home"
mount "$HOME_PART" "$MOUNT/home"

echo "extracting rootfs"
if [ -n "$STREAM_PORT" ]; then
  nc -l -p "$STREAM_PORT" | tar -C "$MOUNT" -xf -
else
  case "$ROOTFS" in
    *.zst) tar --zstd -C "$MOUNT" -xf "$ROOTFS" ;;
    *)     tar -C "$MOUNT" -xf "$ROOTFS" ;;
  esac
fi

[ -f "$MOUNT/etc/fstab.b2q" ] && mv -f "$MOUNT/etc/fstab.b2q" "$MOUNT/etc/fstab"
mkdir -p "$MOUNT/boot"
cp "$BOOTIMG" "$MOUNT/boot/boot.img"

sync
umount "$MOUNT/home" "$MOUNT"

cat <<EOF

Done. The rootfs is in place but not bootable yet:
  1. write boot.img into the boot partition (tools/flash.sh --partition boot on the host,
     or dd from the rescue image)
  2. reboot and expect the USB serial console; M2's ssh comes up on 172.16.42.1
EOF
