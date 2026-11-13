#!/bin/bash
# SPDX-License-Identifier: MIT
# verify-zflip3-image.sh: refuse a root file system that is not what a generic image must be.
#   verify-zflip3-image.sh [--deny FILE] <root dir>
# Checks: an empty machine-id; no ssh host keys, no authorized_keys anywhere; no NetworkManager
# profile in /etc (Wi-Fi passwords, a carrier's APN); no package cache, pacman log or shell
# history; the hostname is zflip3; exactly one user with a home; the kernel, its device tree and the
# boot image are there. --deny FILE: fixed strings (one per line, # comments) that must not appear
# in any file: keep your own hostname, addresses and names in such a file outside git, so the
# check itself never publishes them.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "verify: run as root, or files only root can read go unchecked" >&2; exit 2; }
deny=
if [ "${1:-}" = --deny ]; then deny=${2:?}; shift 2; fi
r=${1:?usage: $0 [--deny FILE] <root dir>}
fail=0
bad() { echo "verify: $*" >&2; fail=1; }

[ -e "$r/etc/machine-id" ] && [ ! -s "$r/etc/machine-id" ] || bad "machine-id is not empty"
[ "$(cat "$r/etc/hostname" 2>/dev/null)" = zflip3 ] || bad "hostname is not zflip3"
compgen -G "$r/etc/ssh/ssh_host_*" >/dev/null && bad "ssh host keys in the image"
[ -z "$(find "$r/root" "$r/home" -name authorized_keys 2>/dev/null)" ] || bad "authorized_keys in the image"
[ -z "$(find "$r/etc/NetworkManager/system-connections" -type f 2>/dev/null)" ] || bad "NetworkManager profiles in /etc"
[ -z "$(find "$r/var/cache/pacman/pkg" -type f 2>/dev/null)" ] || bad "package cache not empty"
[ ! -e "$r/var/log/pacman.log" ] || bad "pacman.log in the image"
[ -z "$(find "$r/root" "$r/home" -name '.*_history' 2>/dev/null)" ] || bad "shell history in the image"
homes=$(find "$r/home" -mindepth 1 -maxdepth 1 -type d | wc -l)
[ "$homes" -eq 1 ] || bad "$homes home directories, not 1"
compgen -G "$r/usr/lib/modules/*-zflip3/vmlinuz" >/dev/null || bad "no linux-zflip3 kernel"
compgen -G "$r/usr/lib/modules/*-zflip3/dtb/qcom/sm8350-samsung-b2q.dtb" >/dev/null || bad "no b2q device tree"
[ -s "$r/boot/linux-zflip3.img" ] || bad "no boot image (zflip3-boot)"
grep -q '^\[zflip3\]' "$r/etc/pacman.conf" || bad "pacman.conf has no [zflip3]"
! grep -q '^Server = file://' "$r/etc/pacman.conf" || bad "pacman.conf points at a local repo"

if [ -n "$deny" ]; then
	pats=$(grep -v '^\s*#' "$deny" | grep -v '^\s*$' || :)
	if [ -n "$pats" ]; then
		hits=$(grep -rIlF -f <(printf '%s\n' "$pats") "$r" 2>/dev/null | head -20 || :)
		[ -z "$hits" ] || bad "denied strings in: $(echo $hits)"
	fi
fi

[ "$fail" = 0 ] && echo "verify: $r is a generic image"
exit $fail
