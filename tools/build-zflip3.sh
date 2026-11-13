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
#   VERIFYSOURCE=1 only download and verify the sources (checksums, PGP signatures), build nothing
# makepkg sees ZFLIP3_QEMU_USER=1 when it runs under qemu-user (x86_64 hosts): a check() can leave
# out tests of what qemu-user cannot do (clone3, namespaces) and still run them on the phone.
#   ZFLIP3_ACCEL   how C/C++ gets compiled in the builder:
#                    xgcc  (default on x86_64) drzee's exact gcc + binutils (+ ccache) rebuilt as
#                          x86_64 cross tools (mkxtools-zflip3.sh) and run natively inside the AArch64
#                          container; when drzee's versions in the sync db moved past them, they are
#                          rebuilt first (lib-zflip3.sh xtools_use). Needs the zflip3-fetch image
#                    none  everything under qemu-user (the only mode on an aarch64 host)
# On an x86_64 host everything else runs under qemu-user: fine for small packages, hours for the
# kernel, which is better built natively (makepkg on the phone or another aarch64 machine).
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-zflip3.sh"

src=$(realpath "${1:?usage: $0 <arch checkout> <package dir>...}"); shift
[ $# -gt 0 ] || { echo "no package given" >&2; exit 1; }
if [ "$HOSTARCH" = aarch64 ]; then ACCEL=${ZFLIP3_ACCEL:-none}; else ACCEL=${ZFLIP3_ACCEL:-xgcc}; fi
case $ACCEL in
	none) ;;
	xgcc) [ "$HOSTARCH" = x86_64 ] || { echo "ZFLIP3_ACCEL=xgcc is for x86_64 hosts" >&2; exit 1; } ;;
	*) echo "ZFLIP3_ACCEL=$ACCEL?" >&2; exit 1 ;;
esac
[ -n "${VERIFYSOURCE:-}" ] && ACCEL=none	# nothing is compiled
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
	local pkg=$1 log t0 c xt=()
	log=$W/logs/$pkg-$(date +%Y%m%d-%H%M%S).log
	[ -e "$src/$pkg/PKGBUILD" ] || { echo "$src/$pkg/PKGBUILD missing" >&2; return 1; }
	senpai_tarball "$src/$pkg/PKGBUILD"
	t0=$(date +%s)
	if [ "$ACCEL" = xgcc ]; then
		# x86_64 tools of drzee's versions as of this sync (rebuilt here when drzee moved), held
		# until the build ends. The container's own pacman -Syu may still see a newer db: then
		# xtools-activate refuses and the build fails rather than mixing versions
		fetch_sync > "$log" 2>&1
		xtools_use || { log "$pkg: no xtools for drzee's current versions"; return 1; }
		xt=(-v "$W/xtools:/opt/zflip3-xtools:ro" -v "$TOOLS/xtools-activate.sh:/usr/local/bin/xtools-activate:ro")
	fi
	log "$pkg: building, accel $ACCEL ($log)"
	mkdir -p "$W/out/$pkg"
	# shellcheck disable=SC2016
	"$ENGINE" run --rm "${EMU[@]}" "${xt[@]}" \
		-v "$src/$pkg:/pkgsrc:ro" -v "$REPO:/repo" -v "$W/pkgcache:/var/cache/pacman/pkg" \
		-v "$W/srcdest:/srcdest" -v "$W/ccache:/ccache" -v "$W/out/$pkg:/out" -e ACCEL="$ACCEL" \
		-e NOCHECK="${NOCHECK:-}" -e VERIFYSOURCE="${VERIFYSOURCE:-}" \
		-e ZFLIP3_QEMU_USER="$([ "$HOSTARCH" = aarch64 ] || echo 1)" localhost/zflip3-builder bash -euc '
		pacman -Syu --noconfirm >/dev/null
		cp -r /pkgsrc /build && chown -R builder: /build /out /srcdest /ccache
		cd /build
		# the set makepkg -s would install, as root here: sudo cannot work under qemu-user
		# (setuid needs binfmt_misc'"'"'s C flag); the packages being built are left out
		su builder -c "makepkg --printsrcinfo" > .SRCINFO
		mine=$(sed -n "s/^pkgname = //p" .SRCINFO)
		keys="depends|makedepends"; [ -n "$NOCHECK" ] || keys="$keys|checkdepends"
		# the pkgbase section only, as makepkg -s does: split packages'"'"' own depends are
		# runtime ones, which makepkg does not install
		deps=$(sed -n "/^pkgname = /q;p" .SRCINFO | sed -nE "s/^\t($keys) = //p" |
			sed -E "s/[<>=].*//" | sort -u | grep -vxF "$mine" || :)
		# the keys a signed source is checked against (kernel.org tarballs: Linus, Greg)
		pgpkeys=$(sed -n "s/^\tvalidpgpkeys = //p" .SRCINFO | sort -u | tr "\n" " ")
		[ -z "$pgpkeys" ] || su builder -c "gpg --batch --keyserver hkps://keyserver.ubuntu.com --recv-keys $pgpkeys"
		if [ -n "$VERIFYSOURCE" ]; then
			su builder -c "SRCDEST=/srcdest makepkg --verifysource -f"
			exit 0
		fi
		echo "zflip3-timing: deps $(date +%s)"
		[ -z "$deps" ] || pacman -S --noconfirm --needed --asdeps $deps
		# after the deps: a dep that pulls in gcc or binutils would put the AArch64 ones back
		[ "$ACCEL" != xgcc ] || xtools-activate
		echo "zflip3-timing: makepkg $(date +%s)"
		# the PATH a login shell gets from /etc/profile.d/perlbin.sh: the perl tools (pod2man & co.) are
		# in /usr/bin/core_perl, and su -c is no login shell
		ENVS="PATH=/usr/local/sbin:/usr/local/bin:/usr/bin:/usr/bin/site_perl:/usr/bin/vendor_perl:/usr/bin/core_perl CCACHE_DIR=/ccache SRCDEST=/srcdest PKGDEST=/out ZFLIP3_QEMU_USER=$ZFLIP3_QEMU_USER"
		# the build tree goes with the container: keep what failed tests wrote
		testlogs() {
			for t in $(find /build/src -name testlog.txt -path "*meson-logs*" 2>/dev/null); do
				echo "==> $t (failed tests)"
				# one section per test from its "==== N/M ====" header: those whose result is
				# neither a pass nor a skip (77)
				awk "function out() { if (buf != \"\" && bad) printf \"%s\", buf }
					/^=+ [0-9]+\/[0-9]+ =+\$/ { out(); buf=\"\"; bad=0 }
					/^result: / && !/exit status 0\$/ && !/exit status 77\$/ && !/skipped/ { bad=1 }
					{ buf = buf \$0 \"\n\" } END { out() }" "$t" | tail -n 400
			done
		}
		if [ "$ACCEL" = xgcc ] && [ -z "$NOCHECK" ]; then
			# Tests run what the package just built, and the x86_64 python from xtools can load
			# neither its AArch64 python modules nor an AArch64 LD_PRELOAD (libcamera'"'"'s
			# pybindings and v4l2-compat tests). So: build and package with the native tools,
			# put drzee'"'"'s own python back, then run check() by itself as makepkg does (in
			# $srcdir, its makepkg.conf environment, errexit); the packages only reach the repo
			# if it passes.
			su builder -c "$ENVS makepkg -f --noconfirm --nocheck" || { testlogs; exit 1; }
			pacman -S --noconfirm python > /dev/null
			echo "zflip3: check() with drzee'"'"'s python"
			su builder -c "$ENVS bash -euc '"'"'
				source /etc/makepkg.conf
				for f in /etc/makepkg.conf.d/*.conf; do [ -e \"\$f\" ] && source \"\$f\"; done
				export CFLAGS CXXFLAGS LDFLAGS MAKEFLAGS NINJAFLAGS CHOST CARCH
				cd /build && source ./PKGBUILD
				srcdir=/build/src startdir=/build
				declare -F check > /dev/null || exit 0
				cd \"\$srcdir\" && check
			'"'"'" || { testlogs; exit 1; }
		else
			su builder -c "$ENVS makepkg -f --noconfirm ${NOCHECK:+--nocheck}" || { testlogs; exit 1; }
		fi
	' >> "$log" 2>&1 || { exec 8>&-; log "$pkg: FAILED, see $log"; return 1; }
	exec 8>&-	# xtools_use's lock
	local t1 td tm; t1=$(date +%s)
	td=$(sed -n 's/^zflip3-timing: deps //p' "$log" | tail -1); tm=$(sed -n 's/^zflip3-timing: makepkg //p' "$log" | tail -1)
	[ -z "$tm" ] || log "$pkg: prep (sync, upgrade, .SRCINFO) $((td - t0))s, deps $((tm - td))s, makepkg $((t1 - tm))s"
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
