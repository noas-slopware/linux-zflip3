#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the small bring-up initramfs used by M1: a static busybox, one init script,
# and nothing else. Purpose-built for a phone with no accessible UART: the shell
# comes up on the USB gadget serial port (ttyGS0), and a heartbeat is printed so a
# screen-less boot still tells you whether the kernel got this far.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: build-initramfs.sh --busybox PATH [--out PATH] [--extra DIR]

  --busybox PATH  static aarch64 busybox binary (required)
  --out PATH      output cpio.gz (default: out/initramfs.cpio.gz)
  --extra DIR     copy this tree into the initramfs root (firmware, test binaries)

A static aarch64 busybox is not in the Arch repos. Alpine's busybox-static apk works:
  curl -O https://dl-cdn.alpinelinux.org/alpine/latest-stable/main/aarch64/APKINDEX.tar.gz
or grab it from any aarch64 Alpine rootfs and pass the path here.

The kernel needs CONFIG_USB_G_SERIAL=y (or g_serial built in) for ttyGS0 to exist.
EOF
}

BUSYBOX=""; OUT="$REPO_ROOT/out/initramfs.cpio.gz"; EXTRA=""

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --busybox) BUSYBOX=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --extra) EXTRA=${2:?}; shift 2 ;;
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
if [ -n "$EXTRA" ]; then
  [ -d "$EXTRA" ] || die "no such directory: $EXTRA"
  cp -a "$EXTRA/." "$STAGE/"
fi

mkdir -p "$(dirname -- "$OUT")"
( cd "$STAGE" && find . -print0 | cpio --null -o -H newc --owner=0:0 --reproducible --quiet | gzip -9 ) > "$OUT"
log "$OUT: $(stat -c%s "$OUT") bytes"
