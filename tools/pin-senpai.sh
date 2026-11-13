#!/bin/bash
# SPDX-License-Identifier: MIT
# pin-senpai.sh: point every PKGBUILD that builds from a senpai tarball (_zf3commit=) at one commit
# of a senpai checkout, put that tarball into SRCDEST, and replace the old tarball's checksum with
# the new one (the other sources keep theirs).
#   pin-senpai.sh <senpai checkout> [commit, default HEAD]
# The tarball is GitHub's own archive of the commit when the commit is on GitHub: makepkg downloads
# exactly those bytes in CI, and GitHub's gzip is not git archive's (same tar inside, other
# checksum). Before the commit is pushed it is git archive's, laid out the same way
# (linux-zflip3-<commit>/); run this again after pushing, which re-pins the same commit to
# GitHub's bytes.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-zflip3.sh"
senpai=${1:?usage: $0 <senpai checkout> [commit]}
new=$(git -C "$senpai" rev-parse "${2:-HEAD}^{commit}")
tar=$W/srcdest/linux-zflip3-$new.tar.gz
cd "$(dirname "$TOOLS")"

# the checksum each PKGBUILD has for its current tarball, read before that file can be replaced
# (re-pinning the same commit replaces it)
declare -A oldsum
for p in */PKGBUILD; do
	old=$(sed -n 's/^_zf3commit=//p' "$p")
	[ -n "$old" ] || continue
	oldtar=$W/srcdest/linux-zflip3-$old.tar.gz
	[ -e "$oldtar" ] || { echo "$p: $oldtar missing, cannot tell which checksum is the tarball's" >&2; exit 1; }
	oldsum[$p]=$(sha256sum "$oldtar" | cut -d' ' -f1)
	grep -q "'${oldsum[$p]}'" "$p" || { echo "$p: no checksum ${oldsum[$p]} for the old tarball" >&2; exit 1; }
done

if curl -fsSL --retry 3 -o "$tar.part" "https://github.com/noas-slopware/linux-zflip3/archive/$new.tar.gz"; then
	echo "linux-zflip3-$new.tar.gz: GitHub's archive"
else
	# overwrites whatever a failed download left in the .part file
	git -C "$senpai" archive --format=tar.gz --prefix="linux-zflip3-$new/" -o "$tar.part" "$new"
	echo "linux-zflip3-$new.tar.gz: git archive (not on GitHub yet: run this again after pushing)" >&2
fi
mv -f "$tar.part" "$tar"
sum=$(sha256sum "$tar" | cut -d' ' -f1)

for p in "${!oldsum[@]}"; do
	old=$(sed -n 's/^_zf3commit=//p' "$p")
	sed -i "s/^_zf3commit=$old\$/_zf3commit=$new/; s/'${oldsum[$p]}'/'$sum'/" "$p"
	echo "${p%/PKGBUILD}: $old -> $new"
done
