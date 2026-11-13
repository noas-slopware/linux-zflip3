#!/bin/bash
# SPDX-License-Identifier: MIT
# pin-senpai.sh: point every PKGBUILD that builds from a senpai tarball (_zf3commit=) at one commit
# of a senpai checkout, make that tarball with git archive into SRCDEST, and replace the old
# tarball's checksum with the new one (the other sources keep theirs).
#   pin-senpai.sh <senpai checkout> [commit, default HEAD]
# The tarball is named and laid out like GitHub's archive of the commit (linux-zflip3-<commit>/).
# Check GitHub's own archive against the checksum once the commit is pushed.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-zflip3.sh"
senpai=${1:?usage: $0 <senpai checkout> [commit]}
new=$(git -C "$senpai" rev-parse "${2:-HEAD}^{commit}")
tar=$W/srcdest/linux-zflip3-$new.tar.gz
[ -e "$tar" ] || git -C "$senpai" archive --format=tar.gz --prefix="linux-zflip3-$new/" -o "$tar" "$new"
sum=$(sha256sum "$tar" | cut -d' ' -f1)
cd "$(dirname "$TOOLS")"
for p in */PKGBUILD; do
	old=$(sed -n 's/^_zf3commit=//p' "$p")
	[ -n "$old" ] || continue
	oldtar=$W/srcdest/linux-zflip3-$old.tar.gz
	sed -i "s/^_zf3commit=$old\$/_zf3commit=$new/" "$p"
	if [ -e "$oldtar" ]; then
		oldsum=$(sha256sum "$oldtar" | cut -d' ' -f1)
		grep -q "'$oldsum'" "$p" || { echo "$p: no checksum $oldsum for the old tarball" >&2; exit 1; }
		sed -i "s/'$oldsum'/'$sum'/" "$p"
	else
		echo "$p: $oldtar missing, update its checksum by hand ($sum)" >&2
	fi
	echo "${p%/PKGBUILD}: $old -> $new"
done
