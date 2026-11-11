#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the Arch Linux Ports aarch64 rootfs for the phone, and pack it as a tar.
#
# Starts from the drzee.net bootstrap tarball. The running pacman is x86_64, so the
# rootfs' own aarch64 pacman runs inside arch-chroot through qemu binfmt. The ports
# packages are signed with drzee.net's key, which is not in archlinux-keyring: it is
# imported by pinned fingerprint, then archports-keyring takes over.
#
# On the phone, / is one F2FS on LVM (VG b2q, LV root) spanning the old super and
# userdata partitions; userspace/installer/install-rootfs.sh writes it there.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
load_sources

usage() {
  cat <<'EOF'
usage: sudo build-rootfs.sh --authorized-keys FILE [options]

  --authorized-keys FILE  ssh public keys for root (required: password login is off)
  --dest DIR              rootfs directory (default: out/rootfs)
  --tar PATH              packed rootfs (default: out/rootfs.tar)
  --firmware DIR          vendor firmware tree to copy over / (default: out/firmware,
                          from tools/extract-wcn-firmware.sh; skipped if missing)
  --tree DIR              kernel tree to take modules from
                          (default: .cache/linux-$LINUX_VERSION)
  --packages DIR          install every package in DIR (*.pkg.tar*), the ones built
                          from userspace/ on the phone; their dependencies come from
                          the repos
  --tarball NAME          bootstrap tarball name (default: ARCH_TARBALL from sources.lock)
  --keep-tarball          do not delete the downloaded tarball

Packages: base from the bootstrap, $ROOTFS_PACKAGES from sources.lock, the phone's repo
packages from userspace/rootfs-packages.txt, then --packages.
EOF
}

DEST="$REPO_ROOT/out/rootfs"
TAR="$REPO_ROOT/out/rootfs.tar"
TREE="$REPO_ROOT/.cache/linux-$LINUX_VERSION"
FIRMWARE="$REPO_ROOT/out/firmware"
PACKAGES=""
TARBALL="$ARCH_TARBALL"
KEYS=""
KEEP=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --authorized-keys) KEYS=${2:?}; shift 2 ;;
    --dest) DEST=${2:?}; shift 2 ;;
    --tar) TAR=${2:?}; shift 2 ;;
    --tree) TREE=${2:?}; shift 2 ;;
    --firmware) FIRMWARE=${2:?}; shift 2 ;;
    --packages) PACKAGES=${2:?}; shift 2 ;;
    --tarball) TARBALL=${2:?}; shift 2 ;;
    --keep-tarball) KEEP=1; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$KEYS" ] || { usage >&2; exit 1; }
[ -f "$KEYS" ] || die "no such file: $KEYS"
[ "$(id -u)" -eq 0 ] || die "needs root (arch-chroot, file ownership)"
[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ] || die "qemu binfmt for aarch64 is not registered (systemctl restart systemd-binfmt)"
[ -f "$TREE/arch/arm64/boot/Image" ] || die "no built kernel in $TREE (run tools/build-kernel.sh)"
need curl tar zstd sha256sum gpg arch-chroot make systemd-firstboot
[ -d "$DEST" ] && die "$DEST already exists; remove it first"
[ -z "$PACKAGES" ] || [ -d "$PACKAGES" ] || die "no such directory: $PACKAGES"
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

# pacman needs / to be a mount point to work out free space.
mount --bind "$DEST" "$DEST"
trap 'umount "$DEST" 2>/dev/null || true' EXIT
chroot_run() { arch-chroot "$DEST" "$@"; }

log "importing the ports signing key ($ARCH_PORTS_KEY_FPR)"
curl -fsSL "$ARCH_PORTS_KEY_URL" -o "$DEST/root/ports.key"
fpr=$(gpg --show-keys --with-colons "$DEST/root/ports.key" | awk -F: '/^fpr/{print $10; exit}')
[ "$fpr" = "$ARCH_PORTS_KEY_FPR" ] || die "ports key fingerprint is $fpr, expected $ARCH_PORTS_KEY_FPR"
chroot_run pacman-key --init
chroot_run pacman-key --populate archlinux
chroot_run pacman-key --add /root/ports.key
chroot_run pacman-key --lsign-key "$ARCH_PORTS_KEY_FPR"
rm -f "$DEST/root/ports.key"

log "installing archports-keyring $ROOTFS_PACKAGES"
# shellcheck disable=SC2086
chroot_run pacman -Sy --noconfirm --needed archports-keyring $ROOTFS_PACKAGES
chroot_run pacman-key --populate archports

mapfile -t phone_pkgs < <(grep -v '^#' "$REPO_ROOT/userspace/rootfs-packages.txt")
log "installing the phone's ${#phone_pkgs[@]} repo packages (userspace/rootfs-packages.txt)"
chroot_run pacman -S --noconfirm --needed "${phone_pkgs[@]}"

if [ -n "$PACKAGES" ]; then
  mapfile -t pkgs < <(find "$PACKAGES" -maxdepth 1 -name '*.pkg.tar*' ! -name '*.sig' \
                        ! -name '*-debug-*' | sort)
  [ "${#pkgs[@]}" -gt 0 ] || die "no packages in $PACKAGES"
  log "installing ${#pkgs[@]} packages from $PACKAGES"
  install -d "$DEST/root/pkgs"
  cp "${pkgs[@]}" "$DEST/root/pkgs/"
  chroot_run sh -c 'pacman -U --noconfirm --needed /root/pkgs/*'
  rm -rf "$DEST/root/pkgs"
fi
rm -f "$DEST"/var/cache/pacman/pkg/*

log "kernel modules from $TREE"
make -s -C "$TREE" ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH="$DEST/usr" INSTALL_MOD_STRIP=1 modules_install

if [ -d "$FIRMWARE" ]; then
  log "vendor firmware from $FIRMWARE"
  cp -a --no-preserve=ownership "$FIRMWARE/." "$DEST/"
else
  warn "no $FIRMWARE: Wi-Fi and Bluetooth will lack Samsung's board files (tools/extract-wcn-firmware.sh)"
fi

log "configuration from userspace/rootfs"
cp -a --no-preserve=ownership "$REPO_ROOT/userspace/rootfs/." "$DEST/"
install -d -m700 "$DEST/root/.ssh"
install -m600 "$KEYS" "$DEST/root/.ssh/authorized_keys"
chroot_run systemctl enable systemd-networkd NetworkManager akari-wifi bluetooth sshd \
  serial-getty@ttyGS0
# networkd runs only usb0, which never decides whether the phone is online, so
# its wait-online (enabled above through systemd-networkd's Also=) can only time
# out, holding network-online.target, and imsroha-rcs, for 2 minutes per boot.
# NetworkManager owns the network; its wait-online is the one that counts.
chroot_run systemctl disable systemd-networkd-wait-online.service
chroot_run systemctl enable NetworkManager-wait-online.service
# What the phone runs, for the units the overlay and --packages brought in: the
# modem's file servers, the sensor hub's, IMS, the session.
for unit in rmtfs tqftpserv hexagonrpcd-sdsp ModemManager 81voltd claire imsroha \
            imsroha-bearer imsroha-rcs simamura imsroha-vss-samsung renge plasmalogin \
            systemd-resolved systemd-timesyncd; do
  if [ -e "$DEST/usr/lib/systemd/system/$unit.service" ]; then
    chroot_run systemctl enable "$unit.service"
  else
    warn "$unit.service is not in the image; not enabled"
  fi
done
# Without these, systemd-firstboot stops the first boot to ask on the console, and
# the phone has no keyboard there.
systemd-firstboot --root="$DEST" --force --locale=C.UTF-8 --keymap=us \
  --timezone="$ROOTFS_TIMEZONE" --hostname="$(cat "$REPO_ROOT/userspace/rootfs/etc/hostname")"

log "packing $TAR"
umount "$DEST"
trap - EXIT
tar --numeric-owner --xattrs --xattrs-include='*' -C "$DEST" -cf "$TAR" .
log "$TAR: $(stat -c%s "$TAR") bytes"
