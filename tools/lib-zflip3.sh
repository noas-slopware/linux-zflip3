# SPDX-License-Identifier: MIT
# lib-zflip3.sh: shared settings for the arch branch's build tools (sourced, not run).
#
# Everything runs in containers made from the Arch Linux Ports AArch64 bootstrap of
# arch-linux-repo.drzee.net (ARMv8.2, which the Snapdragon 888 has), under qemu-user on an x86_64
# host and natively on an aarch64 one:
#   zflip3-arch-base     the bootstrap, drzee's signing key trusted by its pinned fingerprint
#   zflip3-builder       + base-devel, ccache, arch-install-scripts, f2fs-tools, user "builder"
#                        with the caller's uid; pacman.conf with [zflip3] (the local repo, at
#                        /repo) between [core] and [extra], so the phone's forks of extra win.
#                        It downloads by itself (pacman without its sandbox, which qemu-user cannot
#                        give it: no Landlock, no seccomp)
#   zflip3-fetch         native to the host (x86_64: Arch Linux; aarch64: zflip3-arch-base), as
#                        root with --security-opt no-new-privileges so pacman's download sandbox
#                        works: reads drzee's AArch64 sync databases natively (drzee_versions),
#                        downloads packages into the shared cache ahead of a qemu container
#                        (fetch_pkgs), and is what the x86_64 tool builds start from
#   zflip3-xbuild        zflip3-fetch + what gcc and binutils build with (mkxtools-zflip3.sh)
# With ZFLIP3_ACCEL=xgcc (build-zflip3.sh, x86_64 default) drzee's gcc, binutils and ccache in the
# builder are swapped for x86_64 builds of the same versions (mkxtools-zflip3.sh, xtools-activate.sh),
# which the kernel runs natively; so are python, ninja, bison, flex, m4, zstd, bsdtar, debugedit, xz,
# gzip, make, bash (= sh), coreutils, sed, gawk, grep, findutils, diffutils, tar, bc, cpio, kmod, file,
# pahole, faked (mkxtools-tools-zflip3.sh: Arch's x86_64 packages of drzee's versions). perl, rustc,
# clang and everything else stay AArch64, under qemu.
# shellcheck shell=bash

W=${ZFLIP3_WORK:-/var/tmp/zflip3-arch-build}	# lots of disk; never /tmp (tmpfs)
TOOLS=$(dirname "$(realpath "${BASH_SOURCE[0]}")")
REPO=${ZFLIP3_REPO:-$W/repo}			# [zflip3] repo dir
ENGINE=${ENGINE:-$(command -v podman >/dev/null 2>&1 && echo podman || echo docker)}
HOSTARCH=$(uname -m)
DRZEE=https://arch-linux-repo.drzee.net/arch
DRZEE_KEY_FPR=9B2C213B21883BB65CE2FB900CF25682E6BA0751
BOOTSTRAP=archlinux-bootstrap-2026.11.01-aarch64.tar.zst
BOOTSTRAP_SHA256=6f0f3033cd72b3bfa8202baa1fd036545465183fce27d5811925646a8b723c4e
JOBS=${JOBS:-$(nproc)}

if [ "$HOSTARCH" = aarch64 ]; then
	EMU=()
	FETCH_FROM=localhost/zflip3-arch-base
else
	# binfmt_misc has qemu-aarch64 without the F flag here, so the interpreter is looked up inside
	# the container: the base image carries /usr/bin/qemu-aarch64-static (Containerfile)
	# QEMU_CPU: qemu-user's default "max" CPU offers SVE, SME and every other extension (configure
	# scripts and tests probe them) and 32-byte cache lines; cortex-a76 is the ARMv8.2 core with
	# exactly drzee's -march extensions (fp16, rcpc, dotprod, crypto) and the phone's 64-byte L1D
	# lines (Cortex-A78 TRM; the X1 is built on the A78), as the x86_64 xtools see too
	QEMU_CPU=${QEMU_CPU:-cortex-a76}
	EMU=(--platform linux/arm64 -e "QEMU_CPU=$QEMU_CPU")
	FETCH_FROM=docker.io/library/archlinux:latest
fi

mkdir -p "$W"/{pacdb/sync,pkgcache,srcdest,ccache,logs,dl} "$REPO"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }

# pacman for the fetcher: the builders' pacman-zflip3.conf (drzee + [zflip3], the repo dir mounted
# at /repo, AArch64 databases) minus DisableSandbox, which only the qemu containers need. Written
# next to the databases it is used with (tmp + rename: parallel builds source this too)
sed '/^DisableSandbox/d' "$TOOLS/pacman-zflip3.conf" > "$W/pacman-fetch.conf.$$"
mv -f "$W/pacman-fetch.conf.$$" "$W/pacman-fetch.conf"
PAC=(pacman --config /w/pacman-fetch.conf --arch aarch64 --dbpath /w/pacdb --cachedir /w/pkgcache
     --gpgdir /w/gnupg --noconfirm)

# fetcher as root (pacman), with the full download sandbox
fetch_root() {
	"$ENGINE" run --rm --security-opt no-new-privileges -v "$W:/w" -v "$REPO:/repo" -v "$TOOLS:/tools:ro" \
		"${FETCH_ARGS[@]}" localhost/zflip3-fetch "$@"
}
# fetcher as the invoking user (makepkg refuses root; files it writes in $W stay the user's)
fetch_user() {
	"$ENGINE" run --rm --security-opt no-new-privileges --user "$(id -u):$(id -g)" -e HOME=/tmp \
		-v "$W:/w" -v "$REPO:/repo" -v "$TOOLS:/tools:ro" "${FETCH_ARGS[@]}" localhost/zflip3-fetch "$@"
}
FETCH_ARGS=()

# refresh the sync databases (drzee core/extra/forge + [zflip3]); an empty [zflip3] db is made on
# first use (parallel builds: one pacman at a time on the shared dbs, cache and repo)
fetch_sync() {
	( flock 9; fetch_root sh -euc '[ -e /repo/zflip3.db ] || repo-add -q /repo/zflip3.db.tar.gz; "$@" -Sy' sh "${PAC[@]}" ) 9> "$W/pacman.lock"
}

# download exactly these repo/pkgname targets (no dependency resolution: resolve() already did it
# against the builder's own local db); signatures are checked against /w/gnupg (drzee key lsigned)
fetch_pkgs() {
	[ $# -gt 0 ] || return 0
	( flock 9; fetch_root "${PAC[@]}" -Swdd "$@" ) 9> "$W/pacman.lock"
}

# a zflip3-builder container with the shared package cache (read-write: the builder downloads what
# the fetcher did not, as build-zflip3.sh's builds do) and the [zflip3] repo
builder() {
	local img=$1; shift
	"$ENGINE" run --rm "${EMU[@]}" -v "$W/pkgcache:/var/cache/pacman/pkg" -v "$REPO:/repo" \
		"${BUILDER_ARGS[@]}" "$img" "$@"
}
BUILDER_ARGS=()

# what pacman -Su + -S --needed <targets> would install in image $1 against the fetcher's sync dbs,
# as repo/pkgname
resolve() {
	local img=$1; shift
	"$ENGINE" run --rm "${EMU[@]}" -v "$W/pacdb/sync:/var/lib/pacman/sync:ro" -v "$REPO:/repo:ro" "$img" \
		pacman -Sup --needed --noconfirm --print-format '%r/%n' "$@" | grep -v '^::\|^warning:' || true
}

# drzee's current versions, "name version" per package, as the builder resolves them (repo order of
# pacman-zflip3.conf: the first repo that has a name wins), read natively from the shared sync dbs
drzee_versions() { fetch_root "${PAC[@]}" -Sl | awk '!seen[$2]++ { print $2, $3 }'; }

# run a script in a builder container brought up to date the way build-zflip3.sh's builds start
# (pacman -Syu, then these packages), with what the fetcher's sync dbs list downloaded natively
# beforehand. The builder's own -Sy may see a newer db than the fetcher did and download the rest
# itself; xtools-activate.sh then refuses whatever no longer matches, so that fails closed:
#   builder_current <pkg>... -- <script> [arg]...
builder_current() {
	local pk=() list pre script
	while [ "$1" != -- ]; do pk+=("$1"); shift; done; shift
	mapfile -t list < <(resolve localhost/zflip3-builder "${pk[@]}")
	fetch_pkgs "${list[@]}" > /dev/null
	pre="pacman -Syu --noconfirm > /dev/null"
	[ ${#pk[@]} -eq 0 ] || pre="$pre; pacman -S --needed --asdeps --noconfirm ${pk[*]} > /dev/null"
	script=$1; shift
	builder localhost/zflip3-builder sh -euc "$pre
$script" sh "$@"
}

# for the x86_64 zflip3-xbuild containers (-e "XGET=$XGET", then eval "$XGET"; after pacman -Sy):
#   xget <name>=<version>...   installs Arch's x86_64 packages of exactly these versions, from the
#                              repos when they have them, else from the Arch archive (pacman checks
#                              the packager signatures either way)
XGET='xget() {
	local a n v repo=() urls=()
	for a; do n=${a%%=*} v=${a#*=}
		if [ "$(pacman -Sddp --print-format %v "$n" 2>/dev/null)" = "$v" ]; then repo+=("$n")
		else urls+=("https://archive.archlinux.org/packages/${n:0:1}/$n/$n-$v-x86_64.pkg.tar.zst"); fi
	done
	[ ${#repo[@]} -eq 0 ] || pacman -S --needed --noconfirm "${repo[@]}" > /dev/null
	[ ${#urls[@]} -eq 0 ] || pacman -U --needed --noconfirm "${urls[@]}" > /dev/null
	for a; do [ "$(pacman -Q "${a%%=*}" | cut -d" " -f2)" = "${a#*=}" ] ||
		{ echo "no x86_64 ${a%%=*} ${a#*=}" >&2; return 1; }; done
}'

# $ZFLIP3_WORK/xtools (ZFLIP3_ACCEL=xgcc) is replaced while no build uses it: a build holds this lock
# shared for as long as its container runs (the container reads ld.so, glibc's iconv modules and the
# libraries from the mount, not only the programs xtools-activate copied), mkxtools-*.sh hold it
# exclusively for their whole run (ZFLIP3_XTOOLS_LOCKED: the scripts they call share it)
XLOCK=$W/xtools.lock
xtools_lock() {
	[ -z "${ZFLIP3_XTOOLS_LOCKED:-}" ] || return 0
	exec 8> "$XLOCK"
	flock -n 8 || { log "xtools: waiting for the builds that use them"; flock 8; }
	export ZFLIP3_XTOOLS_LOCKED=1
}

# what in xtools no longer matches drzee's versions in the sync db: the first stage to rerun and why,
#   "gcc|tools <reason>"   (nothing when everything matches; run after fetch_sync)
#   gcc    mkxtools-zflip3.sh        gcc, binutils, ccache, fakeroot (it runs the other one after it)
#   tools  mkxtools-tools-zflip3.sh  python & co. and the libraries they load
xtools_stale() {
	local -A B
	local n v p d want deps
	while read -r n v; do B[$n]=$v; done < <(drzee_versions)
	[ -e "$W/xtools/.stamp" ] || { echo "gcc no xtools yet"; return; }
	for p in gcc binutils ccache fakeroot; do
		want=$(sed -n "s/^$p=//p" "$W/xtools/.stamp")
		[ "$want" = "${B[$p]:-}" ] || { echo "gcc $p $want -> ${B[$p]:-none}"; return; }
	done
	[ -s "$W/xtools/tools/.stamp" ] || { echo "tools no tools yet"; return; }
	while read -r p v deps; do
		[ "$v" = "${B[$p]:-}" ] || { echo "tools $p $v -> ${B[$p]:-none}"; return; }
		for d in $deps; do [ "${d#*=}" = "${B[${d%%=*}]:-}" ] ||
			{ echo "tools ${d%%=*} ${d#*=} (loaded by $p) -> ${B[${d%%=*}]:-none}"; return; }; done
	done < "$W/xtools/tools/.stamp"
}

# rerun that stage; exit status 3 from the tools stage means Arch's x86_64 glibc (or gcc runtime)
# moved past the one in xtools/lib, which only a full run (mkxtools-zflip3.sh, new zflip3-xbuild
# image) brings along
xtools_refresh() {
	local rc=0
	case $1 in
		gcc) "$TOOLS/mkxtools-zflip3.sh" ;;
		tools) "$TOOLS/mkxtools-tools-zflip3.sh" ;;
		*) echo "xtools stage $1?" >&2; return 1 ;;
	esac || rc=$?
	[ $rc -eq 3 ] || return $rc
	log "xtools: Arch's x86_64 glibc moved, all of them again"
	"$TOOLS/mkxtools-zflip3.sh"
}

# build-zflip3.sh, before each ZFLIP3_ACCEL=xgcc build: xtools that match the sync db, refreshed here
# if drzee moved; returns with fd 8 holding XLOCK shared (close it with "exec 8>&-" after the build)
xtools_use() {
	local i s st
	for i in 1 2 3; do
		s=$(xtools_stale)
		if [ -n "$s" ]; then
			log "xtools: ${s#* } (drzee moved): rebuilding from ${s%% *} on"
			xtools_refresh "${s%% *}" || { log "xtools: refresh failed"; return 1; }
		fi
		st=$(stat -c %Y "$W/xtools/.stamp" "$W/xtools/tools/.stamp" 2>/dev/null || true)
		exec 8> "$XLOCK"; flock -s 8
		# a refresh by a parallel build between the check and the lock replaced them: check again
		[ "$st" = "$(stat -c %Y "$W/xtools/.stamp" "$W/xtools/tools/.stamp" 2>/dev/null || true)" ] && return 0
		exec 8>&-
	done
	return 1
}
