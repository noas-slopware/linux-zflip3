#!/bin/sh
# SPDX-License-Identifier: MIT
# Wipe Android and install the Arch rootfs on the internal UFS.
#
# Runs ON THE PHONE, from the bring-up initramfs, as root. `super` and `userdata`
# become two LVM physical volumes in one volume group (b2q), with a single logical
# volume (root) across both, formatted F2FS: one /, no split /home. The partition
# table, `persist`, `efs`, `param` and the modem partitions are never touched.
#
# The rootfs arrives as a tar over the USB network:
#   phone:  install-rootfs --yes-wipe
#   host:   nc 172.16.42.1 5555 < out/rootfs.tar
#
# DESTRUCTIVE. Dry run unless --yes-wipe is given.

set -eu

VG=b2q
LV=root
PORT=5555
MOUNT=/newroot
DRY=1

usage() {
  cat <<'EOF'
usage: install-rootfs [--yes-wipe] [--port PORT]

  --yes-wipe   actually wipe super and userdata
  --port PORT  TCP port to read the rootfs tar from (default 5555)

Nothing from Android survives. The stock firmware on your PC is the only way back.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --yes-wipe) DRY=0; shift ;;
    --port) PORT=${2:?}; shift 2 ;;
    *) echo "error: unknown option: $1" >&2; exit 1 ;;
  esac
done

# There is no udev here, so no /dev/disk/by-partlabel: find partitions by GPT name.
find_part() {
  for u in /sys/class/block/*/uevent; do
    if grep -qx "PARTNAME=$1" "$u"; then
      echo "/dev/$(grep '^DEVNAME=' "$u" | cut -d= -f2)"
      return 0
    fi
  done
  return 1
}

SUPER=$(find_part super) || { echo "error: no partition named super" >&2; exit 1; }
USERDATA=$(find_part userdata) || { echo "error: no partition named userdata" >&2; exit 1; }
gib() { echo $(( $(cat "/sys/class/block/$(basename "$1")/size") / 2097152 )); }

echo "super:    $SUPER ($(gib "$SUPER") GiB)"
echo "userdata: $USERDATA ($(gib "$USERDATA") GiB)"
echo "result:   VG $VG on both, LV $LV = all of it, F2FS"

if [ "$DRY" = 1 ]; then
  echo
  echo "DRY RUN. This would destroy Android and everything in userdata."
  echo "Re-run with --yes-wipe when that is what you want."
  exit 0
fi

echo
echo "Wiping Android in 10 seconds. Ctrl-C to stop."
sleep 10

for p in "$SUPER" "$USERDATA"; do
  dd if=/dev/zero of="$p" bs=1M count=8 conv=fsync 2>/dev/null
done
lvm pvcreate -ff -y "$SUPER" "$USERDATA"
lvm vgcreate -y "$VG" "$SUPER" "$USERDATA"
lvm lvcreate -y -l 100%FREE -n "$LV" "$VG"
mkfs.f2fs -f -l b2q-root -O extra_attr,inode_checksum,sb_checksum,compression "/dev/$VG/$LV"

mkdir -p "$MOUNT"
mount -t f2fs -o rw,noatime "/dev/$VG/$LV" "$MOUNT"

echo "waiting for the rootfs tar on port $PORT"
# busybox nc drops the connection as soon as its own stdin hits EOF, which is
# immediately when this runs detached from a terminal. Give it a stdin that never
# ends: a fifo held open read-write on fd 3.
mkfifo /tmp/nc-hold
exec 3<>/tmp/nc-hold
nc -l -p "$PORT" <&3 | tar -C "$MOUNT" -xf -
exec 3>&-
rm -f /tmp/nc-hold
sync
echo "installed: $(du -sm "$MOUNT" | cut -f1) MiB"
umount "$MOUNT"
echo "done. Reboot; the initramfs mounts /dev/$VG/$LV and switches to it."
