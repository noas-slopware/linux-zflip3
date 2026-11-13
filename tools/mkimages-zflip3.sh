#!/bin/bash
# SPDX-License-Identifier: MIT
# mkimages-zflip3.sh: make the container images build-zflip3.sh and mkimage-zflip3.sh use
# (docker group or rootless podman; no sudo). See lib-zflip3.sh for what each is.
#   mkimages-zflip3.sh [base] [fetch] [builder]      (default: all three, in this order)
# Re-run "builder" now and then: build-zflip3.sh upgrades each fresh container first anyway.
# "fetch" (native pacman, git, makepkg) is what ZFLIP3_ACCEL=xgcc reads drzee's sync dbs with and
# builds its x86_64 tools from (mkxtools-zflip3.sh); build-zflip3.sh needs it only in that mode.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-zflip3.sh"

BUILDER_PKGS=(base-devel git python ccache arch-install-scripts f2fs-tools lvm2 android-tools)
steps=("$@"); [ ${#steps[@]} -gt 0 ] || steps=(base fetch builder)

mk_base() {
	local ctx=$W/ctx-base
	mkdir -p "$ctx"
	if [ ! -e "$W/dl/$BOOTSTRAP" ]; then
		curl -fL -o "$W/dl/$BOOTSTRAP.part" "$DRZEE/tarballs/os/aarch64/$BOOTSTRAP"
		mv "$W/dl/$BOOTSTRAP.part" "$W/dl/$BOOTSTRAP"
	fi
	echo "$BOOTSTRAP_SHA256  $W/dl/$BOOTSTRAP" | sha256sum -c --quiet
	ln -f "$W/dl/$BOOTSTRAP" "$ctx/bootstrap.tar.zst"
	if [ "$HOSTARCH" = aarch64 ]; then : > "$ctx/qemu-aarch64-static"
	else
		grep -q '^interpreter /usr/bin/qemu-aarch64-static$' /proc/sys/fs/binfmt_misc/qemu-aarch64 ||
			{ echo "binfmt_misc has no qemu-aarch64 -> /usr/bin/qemu-aarch64-static" >&2; exit 1; }
		cp /usr/bin/qemu-aarch64-static "$ctx/"
	fi
	"$ENGINE" build --platform linux/arm64 -f "$TOOLS/Containerfile" -t localhost/zflip3-arch-base "$ctx"
}

mk_fetch() {
	# run + commit instead of a Containerfile: pacman's sandbox needs no-new-privileges, which a
	# build step cannot set (the archlinux image works around that with DisableSandboxFilesystem;
	# here it is removed instead)
	local c=zflip3-fetch-$$
	"$ENGINE" run --name "$c" --security-opt no-new-privileges -v "$TOOLS:/tools:ro" "$FETCH_FROM" sh -euc '
		sed -i "/^DisableSandbox/d" /etc/pacman.conf
		if [ "$(uname -m)" = aarch64 ]; then	# drzee base: drzee servers, its key
			grep -v "^DisableSandbox\|^\[zflip3\]\|^Server = file:///repo\|^SigLevel = Never" /tools/pacman-zflip3.conf > /etc/pacman.conf
			pacman-key --init; pacman-key --populate archlinux
			curl -fsSL "$1/extra/os/aarch64/public.key" -o /tmp/drzee.key
			fpr=$(gpg --show-keys --with-colons /tmp/drzee.key | awk -F: "/^fpr/{print \$10; exit}")
			[ "$fpr" = "$2" ] || { echo "drzee key is $fpr, expected $2" >&2; exit 1; }
			pacman-key --add /tmp/drzee.key && pacman-key --lsign-key "$2" && rm /tmp/drzee.key
		fi
		pacman -Syu --noconfirm --needed base-devel git python
		rm -rf /var/cache/pacman/pkg/*' sh "$DRZEE" "$DRZEE_KEY_FPR" || { "$ENGINE" rm -f "$c" >/dev/null; exit 1; }
	"$ENGINE" commit "$c" localhost/zflip3-fetch >/dev/null
	"$ENGINE" rm "$c" >/dev/null
	# the AArch64 keyring the fetcher checks drzee's signatures with: drzee's key by its pinned
	# fingerprint, lsigned (archports-keyring carries the same key, but is itself an AArch64 package)
	[ -e "$W/gnupg/pubring.gpg" ] || fetch_root sh -euc '
		pacman-key --gpgdir /w/gnupg --init
		pacman-key --gpgdir /w/gnupg --populate archlinux
		curl -fsSL "$1/extra/os/aarch64/public.key" -o /tmp/drzee.key
		fpr=$(gpg --show-keys --with-colons /tmp/drzee.key | awk -F: "/^fpr/{print \$10; exit}")
		[ "$fpr" = "$2" ] || { echo "drzee key is $fpr, expected $2" >&2; exit 1; }
		pacman-key --gpgdir /w/gnupg --add /tmp/drzee.key
		pacman-key --gpgdir /w/gnupg --lsign-key "$2"' sh "$DRZEE" "$DRZEE_KEY_FPR"
}

mk_builder() {
	# run + commit: the steps need the network and the drzee key check, not a build context
	local c=zflip3-builder-$$
	"$ENGINE" run --name "$c" "${EMU[@]}" -e UID_="$(id -u)" -v "$TOOLS:/tools:ro" localhost/zflip3-arch-base bash -euc '
		install -m644 /tools/pacman-zflip3.conf /etc/pacman.conf
		install -m644 /tools/makepkg-zflip3.conf /etc/makepkg.conf.d/zflip3.conf
		# [zflip3] is a bind mount in use; an empty database here keeps pacman happy without it
		mkdir -p /repo && tar -czf /repo/zflip3.db.tar.gz -T /dev/null && ln -sf zflip3.db.tar.gz /repo/zflip3.db
		pacman-key --init
		pacman-key --populate archlinux
		curl -fsSL "$1/extra/os/aarch64/public.key" -o /tmp/drzee.key
		fpr=$(gpg --show-keys --with-colons /tmp/drzee.key | awk -F: "/^fpr/{print \$10; exit}")
		[ "$fpr" = "$2" ] || { echo "drzee key is $fpr, expected $2" >&2; exit 1; }
		pacman-key --add /tmp/drzee.key && pacman-key --lsign-key "$2" && rm /tmp/drzee.key
		pacman -Syu --noconfirm --needed archports-keyring
		pacman-key --populate archports
		shift 3
		pacman -S --noconfirm --needed "$@"
		rm -rf /repo/* /var/cache/pacman/pkg/*
		useradd -m -u "$UID_" builder
		echo "builder ALL=(ALL) NOPASSWD: ALL" > /etc/sudoers.d/builder
	' sh "$DRZEE" "$DRZEE_KEY_FPR" unused "${BUILDER_PKGS[@]}" 2>&1 || { "$ENGINE" rm -f "$c" >/dev/null; exit 1; }
	"$ENGINE" commit "$c" localhost/zflip3-builder
	"$ENGINE" rm "$c" >/dev/null
}

for s in "${steps[@]}"; do
	case $s in
		base) log "image: zflip3-arch-base"; mk_base ;;
		fetch) log "image: zflip3-fetch"; mk_fetch ;;
		builder) log "image: zflip3-builder"; mk_builder ;;
		*) echo "unknown step $s" >&2; exit 1 ;;
	esac
done
