#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build U-Boot for the phone: pinned upstream plus patches/u-boot/.
#
# ABL loads U-Boot from the boot partition like a kernel (gzip with the b2q dtb
# appended), and U-Boot runs on that dtb. U-Boot then boots Linux from the recovery
# partition, or sits in fastboot if that fails. tools/mkimages.sh packs both images.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
load_sources

usage() {
  cat <<'EOF'
usage: build-u-boot.sh [--cross PREFIX] [--jobs N] [--clean]

  --cross PREFIX  cross compiler prefix (default: aarch64-linux-gnu-)
  --jobs N        make -j (default: nproc)
  --clean         start from a fresh checkout

Output: .cache/u-boot/build/u-boot-nodtb.bin
EOF
}

CROSS="aarch64-linux-gnu-"; JOBS=$(nproc); CLEAN=0
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cross) CROSS=${2:?}; shift 2 ;;
    --jobs) JOBS=${2:?}; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done
need git make "${CROSS}gcc"

DIR="$REPO_ROOT/.cache/u-boot"
SRC="$DIR/src"
BUILD="$DIR/build"
[ "$CLEAN" = 1 ] && rm -rf "$SRC" "$BUILD"

if [ ! -d "$SRC/.git" ]; then
  log "cloning U-Boot $UBOOT_VERSION"
  git clone -q --depth 1 --branch "$UBOOT_VERSION" "$UBOOT_GIT" "$SRC"
fi
[ "$(git -C "$SRC" rev-parse "$UBOOT_VERSION^{commit}")" = "$UBOOT_COMMIT" ] \
  || die "$UBOOT_VERSION is not $UBOOT_COMMIT"

log "applying patches/u-boot on $UBOOT_VERSION"
git -C "$SRC" checkout -q --detach "$UBOOT_COMMIT"
git -C "$SRC" reset -q --hard "$UBOOT_COMMIT"
git -C "$SRC" clean -qfd
git -C "$SRC" -c user.name=b2q -c user.email=b2q@localhost am -q "$REPO_ROOT"/patches/u-boot/*.patch

log "configuring (qcom_defconfig qcom-phone.config b2q.config)"
make -s -C "$SRC" O="$BUILD" CROSS_COMPILE="$CROSS" qcom_defconfig qcom-phone.config b2q.config >/dev/null
for sym in CLK_QCOM_SM8350 PINCTRL_QCOM_SM8350 USB_FUNCTION_FASTBOOT UFS_QCOM; do
  grep -q "^CONFIG_$sym=y" "$BUILD/.config" || die "U-Boot CONFIG_$sym did not end up =y"
done

log "building (-j$JOBS)"
make -s -C "$SRC" O="$BUILD" CROSS_COMPILE="$CROSS" -j"$JOBS" >/dev/null
log "$BUILD/u-boot-nodtb.bin"
