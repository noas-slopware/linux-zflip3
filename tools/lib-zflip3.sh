# SPDX-License-Identifier: MIT
# lib-zflip3.sh: shared settings for the arch branch's build tools (sourced, not run).
#
# Everything runs in containers made from the Arch Linux Ports AArch64 bootstrap of
# arch-linux-repo.drzee.net (ARMv8.2, which the Snapdragon 888 has), under qemu-user on an x86_64
# host and natively on an aarch64 one:
#   zflip3-arch-base     the bootstrap, drzee's signing key trusted by its pinned fingerprint
#   zflip3-builder       + base-devel, ccache, arch-install-scripts, f2fs-tools, user "builder"
#                        with the caller's uid; pacman.conf with [zflip3] (the local repo, at
#                        /repo) between [core] and [extra], so the phone's forks of extra win
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
else
	# binfmt_misc has qemu-aarch64 without the F flag here, so the interpreter is looked up inside
	# the container: the base image carries /usr/bin/qemu-aarch64-static (Containerfile)
	EMU=(--platform linux/arm64)
fi

mkdir -p "$W"/{pkgcache,srcdest,ccache,logs,dl} "$REPO"

log() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2; }
