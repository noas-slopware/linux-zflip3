#!/bin/bash
# SPDX-License-Identifier: MIT
# build-zflip3.sh: build packages of the arch branch in fresh zflip3-builder containers (one per
# package = a clean chroot) and add them to the [zflip3] repo. Images come from mkimages-zflip3.sh.
#   build-zflip3.sh <arch branch checkout> <package dir>...
# Environment:
#   ZFLIP3_REPO    repo dir (default $ZFLIP3_WORK/repo)
#   ZFLIP3_WORK    work dir (default /var/tmp/zflip3-arch-build): package/source caches, ccache, logs
#   ZFLIP3_SENPAI  a checkout of the senpai branch: the PKGBUILDs' linux-zflip3-<commit>.tar.gz is
#                  made from it with git archive when SRCDEST lacks it (before the commit is on
#                  GitHub, or to build offline)
#   NOCHECK=1      skip check() (makepkg --nocheck)
# On an x86_64 host everything runs under qemu-user: fine for small packages, hours for the kernel,
# which is better built natively (makepkg on the phone or another aarch64 machine).
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-zflip3.sh"

src=$(realpath "${1:?usage: $0 <arch checkout> <package dir>...}"); shift
[ $# -gt 0 ] || { echo "no package given" >&2; exit 1; }
[ -s "$REPO/zflip3.db.tar.gz" ] || { tar -czf "$REPO/zflip3.db.tar.gz" -T /dev/null; ln -sf zflip3.db.tar.gz "$REPO/zflip3.db"; }

senpai_tarball() {
	local pkgbuild=$1 commit
	commit=$(sed -n 's/^_zf3commit=//p' "$pkgbuild")
	[ -n "$commit" ] || return 0
	[ -e "$W/srcdest/linux-zflip3-$commit.tar.gz" ] && return 0
	[ -n "${ZFLIP3_SENPAI:-}" ] || return 0	# makepkg downloads it from GitHub
	log "linux-zflip3-$commit.tar.gz from $ZFLIP3_SENPAI"
	git -C "$ZFLIP3_SENPAI" archive --format=tar.gz --prefix="linux-zflip3-$commit/" \
		-o "$W/srcdest/linux-zflip3-$commit.tar.gz" "$commit"
}

build_one() {
	local pkg=$1 log t0 c
	log=$W/logs/$pkg-$(date +%Y%m%d-%H%M%S).log
	[ -e "$src/$pkg/PKGBUILD" ] || { echo "$src/$pkg/PKGBUILD missing" >&2; return 1; }
	senpai_tarball "$src/$pkg/PKGBUILD"
	t0=$(date +%s)
	log "$pkg: building ($log)"
	mkdir -p "$W/out/$pkg"
	# shellcheck disable=SC2016
	"$ENGINE" run --rm "${EMU[@]}" \
		-v "$src/$pkg:/pkgsrc:ro" -v "$REPO:/repo" -v "$W/pkgcache:/var/cache/pacman/pkg" \
		-v "$W/srcdest:/srcdest" -v "$W/ccache:/ccache" -v "$W/out/$pkg:/out" \
		-e NOCHECK="${NOCHECK:-}" localhost/zflip3-builder bash -euc '
		pacman -Syu --noconfirm >/dev/null
		cp -r /pkgsrc /build && chown -R builder: /build /out /srcdest /ccache
		cd /build
		# the set makepkg -s would install, as root here: sudo cannot work under qemu-user
		# (setuid needs binfmt_misc'"'"'s C flag); the packages being built are left out
		su builder -c "makepkg --printsrcinfo" > .SRCINFO
		mine=$(sed -n "s/^pkgname = //p" .SRCINFO)
		keys="depends|makedepends"; [ -n "$NOCHECK" ] || keys="$keys|checkdepends"
		deps=$(sed -nE "s/^\t($keys) = //p" .SRCINFO | sed -E "s/[<>=].*//" | sort -u | grep -vxF "$mine" || :)
		[ -z "$deps" ] || pacman -S --noconfirm --needed --asdeps $deps
		su builder -c "CCACHE_DIR=/ccache SRCDEST=/srcdest PKGDEST=/out makepkg -f --noconfirm ${NOCHECK:+--nocheck}"
	' > "$log" 2>&1 || { log "$pkg: FAILED, see $log"; return 1; }
	shopt -s nullglob
	local f n=0
	for f in "$W/out/$pkg"/*.pkg.tar.zst; do
		mv -f "$f" "$REPO/"
		repo-add -q -R "$REPO/zflip3.db.tar.gz" "$REPO/${f##*/}"
		n=$((n + 1))
	done
	shopt -u nullglob
	log "$pkg: $n package(s) in $REPO, $(( $(date +%s) - t0 )) s"
}

rc=0
for p in "$@"; do build_one "${p%/}" || rc=1; done
exit $rc
