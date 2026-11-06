#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build an Arch Linux Ports aarch64 rootfs from the drzee.net bootstrap tarball.
#
# The running pacman is x86_64, so post-install hooks cannot run directly. qemu
# binfmt is registered on this host, so packages that need post-install scripts are
# installed by chrooting with arch-chroot instead of by pacstrap.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
load_sources

usage() {
  cat <<'EOF'
usage: build-rootfs.sh [options]

  --dest DIR        where to put the rootfs (default: out/rootfs)
  --tarball NAME    bootstrap tarball name (default: ARCH_TARBALL from sources.lock)
  --pkg LIST        space separated packages to install in the chroot after unpacking
  --chroot-cmd CMD  run this command inside the rootfs instead of installing --pkg
  --keep-tarball    do not delete the downloaded tarball
  --no-chroot       unpack only

The result is a complete aarch64 Arch install. It is not bootable on the phone until
the kernel is installed and the boot image is regenerated (tools/bootimg.sh).
EOF
}

DEST="$REPO_ROOT/out/rootfs"
TARBALL="$ARCH_TARBALL"
PKGS=""
CHROOT_CMD=""
KEEP=0
DO_CHROOT=1

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --dest) DEST=${2:?}; shift 2 ;;
    --tarball) TARBALL=${2:?}; shift 2 ;;
    --pkg) PKGS=${2:?}; shift 2 ;;
    --chroot-cmd) CHROOT_CMD=${2:?}; shift 2 ;;
    --keep-tarball) KEEP=1; shift ;;
    --no-chroot) DO_CHROOT=0; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

need curl tar zstd sha256sum
[ -d "$DEST" ] && die "$DEST already exists; remove it first"
mkdir -p "$(dirname -- "$DEST")"

CACHE="$REPO_ROOT/.cache"
mkdir -p "$CACHE"
[ -f "$CACHE/$TARBALL" ] || {
  log "downloading $ARCH_TARBALL_URL/$TARBALL"
  curl -fL --retry 3 -o "$CACHE/$TARBALL.part" "$ARCH_TARBALL_URL/$TARBALL"
  mv "$CACHE/$TARBALL.part" "$CACHE/$TARBALL"
}
log "sha256 $(sha256sum "$CACHE/$TARBALL" | cut -d' ' -f1)  $TARBALL"

log "extracting to $DEST"
STAGE=$(mktemp -d "$CACHE/rootfs.XXXXXX")
tar --zstd --numeric-owner --xattrs --xattrs-include='*' -xf "$CACHE/$TARBALL" -C "$STAGE"
# The bootstrap tarball also ships version and pkglist.aarch64.txt at the top level,
# so pick the single directory rather than assuming the archive has one entry.
mapfile -t roots < <(find "$STAGE" -mindepth 1 -maxdepth 1 -type d)
[ "${#roots[@]}" -eq 1 ] || {
  rm -rf "$STAGE"
  die "expected exactly one top-level directory in $TARBALL, found ${#roots[@]}"
}
mv "${roots[0]}" "$DEST"
rm -rf "$STAGE"
[ "$KEEP" = 1 ] || rm -f "$CACHE/$TARBALL"

# Point pacman at the ARMv8.2 ports repos rather than the mirrorlist that ships in the tarball.
cat > "$DEST/etc/pacman.conf" <<EOF
[options]
HoldPkg     = pacman glibc
Architecture = aarch64
Color
CheckSpace
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Server = $ARCH_REPO_CORE
[extra]
Server = $ARCH_REPO_EXTRA
[forge]
Server = $ARCH_REPO_FORGE
EOF

cat > "$DEST/etc/fstab.b2q" <<'EOF'
# Used on the phone. LABELs are set by userspace/installer/install-rootfs.sh.
LABEL=b2q-root  /      ext4  rw,noatime                0 1
LABEL=b2q-home  /home  ext4  rw,noatime                0 2
EOF

if [ "$DO_CHROOT" = 0 ]; then
  log "unpacked only (--no-chroot)"
  exit 0
fi

[ "$(id -u)" -eq 0 ] || die "chrooting needs root; re-run as root, or unpack with --no-chroot"

if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
  cat >&2 <<'EOF'
error: qemu binfmt for aarch64 is not registered, so the rootfs' own pacman cannot run.

  systemctl restart systemd-binfmt
  # or, if /usr/lib/binfmt.d/qemu-aarch64.conf is missing:
  pacman -S qemu-user-static-binfmt

Then re-run. The unpacked rootfs is at DEST and is still usable with --no-chroot.
EOF
  exit 3
fi

if [ -n "$PKGS" ]; then
  # shellcheck disable=SC2086
  CHROOT_CMD="pacman -Sy --noconfirm --needed $PKGS"
fi

if [ -n "$CHROOT_CMD" ]; then
  log "chroot: $CHROOT_CMD"
  arch-chroot "$DEST" /bin/sh -c "$CHROOT_CMD"
fi

cat <<EOF

Rootfs ready: $DEST
  pacman keyring: arch-chroot $DEST pacman-key --init && arch-chroot $DEST pacman-key --populate archlinux
  install more:   arch-chroot $DEST pacman -S <packages>
EOF
