#!/bin/bash
# SPDX-License-Identifier: MIT
# clean-image-root-zflip3.sh: remove the root file system a mkimage-zflip3.sh run left in
# /var/tmp/zflip3-arch-build/image-root. Its files are root's, so the removal runs as root in a
# container that sees only that directory, at /target; only literal paths are removed.
set -euo pipefail
. "$(dirname "$(realpath "$0")")/lib-zflip3.sh"
[ "$W" = /var/tmp/zflip3-arch-build ] || { echo "only the default work dir is handled" >&2; exit 1; }
[ -d /var/tmp/zflip3-arch-build/image-root ] || exit 0
"$ENGINE" run --rm -v /var/tmp/zflip3-arch-build/image-root:/target docker.io/library/archlinux:latest \
	sh -c 'umount -R /target 2>/dev/null; find /target -mindepth 1 -delete'
rmdir /var/tmp/zflip3-arch-build/image-root
