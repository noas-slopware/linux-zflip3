#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the small bring-up initramfs used by M1: a static busybox, one init script,
# and nothing else. Purpose-built for a phone with no accessible UART: init prints a
# marker and any ramoops log on the panel (tty0), then offers a shell on the configfs
# ACM gadget (ttyGS0 on the phone, ttyACM0 on the host).

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: build-initramfs.sh --busybox PATH [--rootfs DIR] [--out PATH] [--extra DIR]

  --busybox PATH  static aarch64 busybox binary (required)
  --out PATH      output cpio.gz (default: out/initramfs.cpio.gz)
  --rootfs DIR    take lvm and mkfs.f2fs (and the libraries they need) from this
                  aarch64 rootfs (tools/build-rootfs.sh); without it the initramfs
                  can neither mount / nor install it
  --extra DIR     copy this tree into the initramfs root (firmware, test binaries)

tools/build-busybox.sh builds the static aarch64 busybox this expects (with telnetd and
udhcpd, which Alpine's busybox-static leaves out).

The kernel needs CONFIG_USB_CONFIGFS=y and CONFIG_USB_CONFIGFS_ACM=y: init builds the ACM
gadget in configfs, and the host sees it as ttyACM0 once the cable is re-plugged.
EOF
}

BUSYBOX=""; OUT="$REPO_ROOT/out/initramfs.cpio.gz"; EXTRA=""; ROOTFS=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --busybox) BUSYBOX=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --extra) EXTRA=${2:?}; shift 2 ;;
    --rootfs) ROOTFS=${2:?}; shift 2 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$BUSYBOX" ] || { usage >&2; exit 1; }
[ -f "$BUSYBOX" ] || die "no such busybox: $BUSYBOX"
file "$BUSYBOX" | grep -q 'ARM aarch64' || warn "busybox does not look like aarch64"
need cpio gzip file

STAGE=$(mktemp -d)
trap 'rm -rf "$STAGE"' EXIT
mkdir -p "$STAGE"/{bin,sbin,proc,sys,dev,tmp,newroot}

install -m755 "$BUSYBOX" "$STAGE/bin/busybox"
for applet in sh ls cat mount umount mkdir mknod echo sleep dmesg poweroff reboot \
              ifconfig ip modprobe vi dd blkid; do
  ln -sf busybox "$STAGE/bin/$applet"
done

install -m755 "$REPO_ROOT/userspace/installer/init" "$STAGE/init"
install -m755 "$REPO_ROOT/userspace/installer/install-rootfs.sh" "$STAGE/bin/install-rootfs"

if [ -n "$ROOTFS" ]; then
  [ -d "$ROOTFS/usr/lib" ] || die "no rootfs at $ROOTFS"
  need readelf
  mkdir -p "$STAGE/usr/lib" "$STAGE/etc/lvm" "$STAGE/run/lock/lvm"
  ln -sf usr/lib "$STAGE/lib"
  # Copy a binary and, recursively, every DT_NEEDED library from the rootfs.
  copy_with_libs() {
    local f=$1 lib
    for lib in $(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p'); do
      [ -e "$STAGE/usr/lib/$lib" ] && continue
      [ -e "$ROOTFS/usr/lib/$lib" ] || die "$lib (needed by $f) is not in $ROOTFS/usr/lib"
      cp -L "$ROOTFS/usr/lib/$lib" "$STAGE/usr/lib/$lib"
      copy_with_libs "$ROOTFS/usr/lib/$lib"
    done
  }
  cp -L "$ROOTFS/usr/lib/ld-linux-aarch64.so.1" "$STAGE/usr/lib/"
  for bin in lvm mkfs.f2fs; do
    install -m755 "$ROOTFS/usr/bin/$bin" "$STAGE/bin/$bin"
    copy_with_libs "$ROOTFS/usr/bin/$bin"
  done
  # No udev in the initramfs: lvm must create the /dev nodes itself.
  cat > "$STAGE/etc/lvm/lvm.conf" <<'EOF'
devices {
	obtain_device_list_from_udev = 0
}
activation {
	udev_sync = 0
	udev_rules = 0
}
EOF
fi
if [ -n "$EXTRA" ]; then
  [ -d "$EXTRA" ] || die "no such directory: $EXTRA"
  cp -a "$EXTRA/." "$STAGE/"
fi

mkdir -p "$(dirname -- "$OUT")"
( cd "$STAGE" && find . -print0 | cpio --null -o -H newc --owner=0:0 --reproducible --quiet | gzip -9 ) > "$OUT"
log "$OUT: $(stat -c%s "$OUT") bytes"
