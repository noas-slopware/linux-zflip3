#!/usr/bin/env bash
# Add package files to the [zflip3] database in <repo dir> with drzee's repo-add (in zflip3-arch-base),
# creating it if needed, and make sure zflip3.db and zflip3.files exist. repo-add given no packages
# writes nothing at all, but pacman needs a database even for an empty repository: an empty
# archive is one.
#
#   repo-db.sh <repo dir> [package file name in <repo dir>]...
set -euo pipefail

repo=$(realpath "$1")
shift
if [ $# -gt 0 ]; then
	docker run --rm --user "$(id -u):$(id -g)" -v "$repo:/repo" -w /repo localhost/zflip3-arch-base \
		repo-add -q zflip3.db.tar.zst "$@"
fi
for db in zflip3.db zflip3.files; do
	[ -e "$repo/$db.tar.zst" ] || tar --zstd -cf "$repo/$db.tar.zst" -T /dev/null
	[ -e "$repo/$db" ] || ln -s "$db.tar.zst" "$repo/$db"
done
