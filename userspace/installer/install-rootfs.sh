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
#   phone:  install-rootfs --yes-wipe --user NAME      (in the telnet shell: passwd needs its pty)
#   host:   zstdcat archlinux-zflip3-rootfs.tar.zst | nc 172.16.42.1 5555
#
# The image has no accounts, like Arch Linux Ports' own root file system: root is locked and there
# is no user. --user makes the one user (in wheel, so sudo works) with the password typed here,
# and, when the image has Plasma Mobile, its autologin (the lock screen asks for that password).
#
# DESTRUCTIVE. Dry run unless --yes-wipe is given.

set -eu

VG=b2q
LV=root
PORT=5555
MOUNT=/newroot
DRY=1
USER_NAME=

usage() {
  cat <<'EOF'
usage: install-rootfs [--yes-wipe] --user NAME [--port PORT]

  --yes-wipe   actually wipe super and userdata
  --user NAME  the user to create (wheel); asks for its password after unpacking
  --port PORT  TCP port to read the rootfs tar from (default 5555)

Nothing from Android survives. The stock firmware on your PC is the only way back.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --yes-wipe) DRY=0; shift ;;
    --port) PORT=${2:?}; shift 2 ;;
    --user) USER_NAME=${2:?}; shift 2 ;;
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

[ -n "$USER_NAME" ] || { echo "error: --user NAME is needed: the image has no account to log in with" >&2; exit 1; }
# useradd's own rule for names (NAME_REGEX's default)
echo "$USER_NAME" | grep -qE '^[a-z_][a-z0-9_-]*[$]?$' && [ ${#USER_NAME} -le 32 ] ||
  { echo "error: '$USER_NAME' is not a valid user name" >&2; exit 1; }
[ "$USER_NAME" != root ] || { echo "error: root stays locked; name a user" >&2; exit 1; }
[ -t 0 ] || { echo "error: run this in the telnet shell: the password is asked on its terminal" >&2; exit 1; }

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

# the account, with the image's own useradd and passwd (PAM, yescrypt as Arch sets it)
for d in proc sys dev; do mount --bind "/$d" "$MOUNT/$d"; done
chroot "$MOUNT" useradd -m -G wheel,video,audio,input,render -s /bin/bash "$USER_NAME"
echo "password for $USER_NAME:"
until chroot "$MOUNT" passwd "$USER_NAME"; do echo "again:"; done
if [ -e "$MOUNT/usr/lib/systemd/system/plasmalogin.service" ]; then
  mkdir -p "$MOUNT/etc/plasmalogin.conf.d"
  printf '[Autologin]\nUser=%s\nSession=plasma-mobile.desktop\n' "$USER_NAME" \
    > "$MOUNT/etc/plasmalogin.conf.d/autologin.conf"
fi
for d in dev sys proc; do umount "$MOUNT/$d"; done
sync
umount "$MOUNT"
echo "done. Reboot; the initramfs mounts /dev/$VG/$LV and switches to it."
