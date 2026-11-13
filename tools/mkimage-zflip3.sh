#!/bin/bash
# SPDX-License-Identifier: MIT
# mkimage-zflip3.sh: build the generic Galaxy Z Flip3 (SM-F711N) Arch Linux Ports root file system
# from [zflip3] (the repo build-zflip3.sh fills) and drzee's repos, inside a privileged
# zflip3-builder container (mounts for pacstrap), check it with verify-zflip3-image.sh and pack it.
# No personal settings: hostname zflip3, one user (wheel), C.UTF-8, Asia/Seoul (every SM-F711N is
# Korean), an empty machine-id (made at first boot), no ssh keys, no carrier but the generic one.
#   [USERNAME=archlinux PASSWORD=archlinux ROOT_PASSWORD=root] mkimage-zflip3.sh <outdir>
# Out: <outdir>/archlinux-zflip3-rootfs.tar.zst, the tar userspace/installer/install-rootfs.sh
#      (senpai branch) unpacks onto the F2FS on LVM, and linux-zflip3.img, the boot image zflip3-boot
#      made for the recovery partition (on the phone it writes it there itself on every update).
# ZFLIP3_IMAGE_PKGS="pkg ..." replaces the package list below; ZFLIP3_REPO_URL is where the image's
# pacman finds [zflip3] (default: the GitHub Pages URL it will be published at).
# ZFLIP3_VERIFY_DENY=<file>: extra patterns the image must not contain, one per line, handed to
# verify-zflip3-image.sh (keep a list of your own hostname, addresses and names there, outside git).
set -euo pipefail

out=${1:?usage: $0 <outdir>}
user=${USERNAME:-archlinux}
export USERNAME="$user" PASSWORD=${PASSWORD:-archlinux} ROOT_PASSWORD=${ROOT_PASSWORD:-root}
REPO_URL=${ZFLIP3_REPO_URL:-https://noas-slopware.github.io/linux-zflip3/arch/\$arch}
PKGS=(base linux-zflip3 linux-zflip3-dtbs mkinitcpio firmware-zflip3 zflip3-device
	networkmanager openssh sudo vim nano)
[ -z "${ZFLIP3_IMAGE_PKGS:-}" ] || read -ra PKGS <<< "$ZFLIP3_IMAGE_PKGS"

if [ -z "${ZFLIP3_IN_CONTAINER:-}" ]; then
	. "$(dirname "$(realpath "$0")")/lib-zflip3.sh"
	mkdir -p "$out"; out=$(realpath "$out")
	root=$W/image-root
	[ ! -e "$root" ] || { echo "$root exists (a previous run); remove it first" >&2; exit 1; }
	mkdir -p "$root"
	"$ENGINE" run --rm --privileged "${EMU[@]}" -e ZFLIP3_IN_CONTAINER=1 \
		-e USERNAME -e PASSWORD -e ROOT_PASSWORD -e ZFLIP3_IMAGE_PKGS -e REPO_URL="$REPO_URL" \
		-v "$REPO:/repo:ro" -v "$W/pkgcache:/var/cache/pacman/pkg" -v "$TOOLS:/tools:ro" \
		-v "$root:/target" localhost/zflip3-builder /tools/mkimage-zflip3.sh /target
	# as root in the container: the image's files are root's, and a check that cannot read
	# /root or /etc/shadow proves nothing about them
	deny=() mnt=()
	if [ -n "${ZFLIP3_VERIFY_DENY:-}" ]; then
		deny=(--deny /deny.txt) mnt=(-v "$(realpath "$ZFLIP3_VERIFY_DENY"):/deny.txt:ro")
	fi
	# natively (no qemu needed to read files): the Arch Linux image the base image is extracted with
	"$ENGINE" run --rm -v "$root:/target:ro" -v "$TOOLS:/tools:ro" "${mnt[@]}" \
		docker.io/library/archlinux:latest /tools/verify-zflip3-image.sh "${deny[@]}" /target
	log "packing $out/archlinux-zflip3-rootfs.tar.zst"
	"$ENGINE" run --rm -v "$root:/target:ro" -v "$out:/out" docker.io/library/archlinux:latest \
		sh -euc 'tar --numeric-owner --xattrs --xattrs-include="*" --acls -C /target -cf - . |
			zstd -T0 -19 -q -o /out/archlinux-zflip3-rootfs.tar.zst; cp /target/boot/linux-zflip3.img /out/'
	( cd "$out" && sha256sum archlinux-zflip3-rootfs.tar.zst linux-zflip3.img > sha256sums )
	cat "$out/sha256sums"
	exit 0
fi

# --- inside the container ------------------------------------------------------------------------
# the target is always /target (the bind mount above), so every path below can be literal
[ "$1" = /target ] || { echo "inside the container the target is /target, not $1" >&2; exit 1; }
t=/target
pacman -Sy --noconfirm >/dev/null
mountpoint -q "$t" || mount --bind "$t" "$t"
pacstrap -C /etc/pacman.conf -K "$t" "${PKGS[@]}"

# the image's pacman: drzee and the published [zflip3], drzee's key trusted as in the builder
sed "s|^Server = file:///repo$|Server = $REPO_URL|; /^DisableSandbox$/d; /^# qemu-user implements/d" \
	/etc/pacman.conf > "$t/etc/pacman.conf"
arch-chroot "$t" pacman-key --populate archports >/dev/null 2>&1 || :
pacman-key --export 9B2C213B21883BB65CE2FB900CF25682E6BA0751 > "$t/root/drzee.key"
arch-chroot "$t" sh -c 'pacman-key --add /root/drzee.key && pacman-key --lsign-key 9B2C213B21883BB65CE2FB900CF25682E6BA0751' >/dev/null
rm -f /target/root/drzee.key

# / is F2FS on LVM (userspace/installer/install-rootfs.sh); swap is zram (zflip3-system)
printf '%s\n' '# <device>     <dir> <type> <options>   <dump> <fsck>' \
	'/dev/b2q/root  /     f2fs   rw,noatime  0      1' > "$t/etc/fstab"
echo zflip3 > "$t/etc/hostname"
echo LANG=C.UTF-8 > "$t/etc/locale.conf"
ln -sf /usr/share/zoneinfo/Asia/Seoul "$t/etc/localtime"
: > "$t/etc/machine-id"

arch-chroot "$t" useradd -m -G wheel,video,audio,input,render -s /bin/bash "$USERNAME"
printf '%s:%s\n' "$USERNAME" "$PASSWORD" root "$ROOT_PASSWORD" | arch-chroot "$t" chpasswd
echo '%wheel ALL=(ALL:ALL) ALL' > "$t/etc/sudoers.d/10-wheel"
chmod 440 "$t/etc/sudoers.d/10-wheel"
# Plasma Mobile starts on its own (lock screen first: zflip3-plasma's kscreenlockerrc)
if [ -e "$t/usr/lib/systemd/system/plasmalogin.service" ]; then
	mkdir -p "$t/etc/plasmalogin.conf.d"
	printf '[Autologin]\nUser=%s\nSession=plasma-mobile.desktop\n' "$USERNAME" \
		> "$t/etc/plasmalogin.conf.d/autologin.conf"
fi

systemctl --root="$t" preset-all
# nothing the build left behind
rm -rf /target/var/cache/pacman/pkg/* /target/var/log/pacman.log /target/root/.bash_history
rm -f /target/etc/ssh/ssh_host_*
