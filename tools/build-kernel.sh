#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Configure and build the kernel for the phone.
#
# The base is the Nura sm8350 config (configs/nura-sm8350.config), which is what
# boots on this SoC; configs/b2q.fragment carries our deltas. merge_config.sh will
# quietly leave a symbol at =m, and a module is useless in an initramfs that has no
# module loader, so the symbols the boot depends on are checked afterwards.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
load_sources

usage() {
  cat <<'EOF'
usage: build-kernel.sh [options]

  --tree DIR      kernel tree (default: .cache/linux-$LINUX_VERSION)
  --base FILE     base .config (default: configs/nura-sm8350.config)
  --fragment FILE kconfig fragment (default: configs/b2q.fragment)
  --cross PREFIX  cross compiler prefix (default: aarch64-linux-gnu-)
  --jobs N        make -j (default: nproc)
  --apply         apply patches/linux/ before configuring
  --config-only   stop after .config is written

Outputs land in the tree; tools/mkimages.sh packs them.
EOF
}

TREE="$REPO_ROOT/.cache/linux-$LINUX_VERSION"
BASE="$REPO_ROOT/configs/nura-sm8350.config"
FRAGMENT="$REPO_ROOT/configs/b2q.fragment"
CROSS="aarch64-linux-gnu-"
JOBS=$(nproc)
APPLY=0
CONFIG_ONLY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --tree) TREE=${2:?}; shift 2 ;;
    --base) BASE=${2:?}; shift 2 ;;
    --fragment) FRAGMENT=${2:?}; shift 2 ;;
    --cross) CROSS=${2:?}; shift 2 ;;
    --jobs) JOBS=${2:?}; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --config-only) CONFIG_ONLY=1; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -d "$TREE" ] || die "no kernel tree at $TREE (run tools/fetch-kernel.sh)"
[ -f "$BASE" ] || die "no base config at $BASE"
[ -f "$FRAGMENT" ] || die "no fragment at $FRAGMENT"
need make gcc

if [ "$APPLY" = 1 ]; then
  for p in "$REPO_ROOT"/patches/linux/[0-9][0-9][0-9][0-9]-*.patch; do
    [ -e "$p" ] || continue
    log "applying $(basename "$p")"
    patch -d "$TREE" -p1 -s -i "$p"
  done
fi

log "$(basename "$BASE") + $(basename "$FRAGMENT")"
cp "$BASE" "$TREE/.config"
"$TREE/scripts/kconfig/merge_config.sh" -m -O "$TREE" "$TREE/.config" "$FRAGMENT" >/dev/null
make -s -C "$TREE" ARCH=arm64 CROSS_COMPILE="$CROSS" olddefconfig

for sym in FB_SIMPLE FRAMEBUFFER_CONSOLE PINCTRL_SM8350 SCSI_UFS_QCOM \
           USB_DWC3_QCOM PHY_QCOM_QMP_COMBO PHY_QCOM_USB_SNPS_FEMTO_V2 \
           USB_CONFIGFS USB_CONFIGFS_ACM BLK_DEV_DM F2FS_FS MFD_MAX77705; do
  grep -q "^CONFIG_$sym=y" "$TREE/.config" || die "CONFIG_$sym did not end up =y"
done
grep -q '^CONFIG_DRM_SIMPLEDRM=y' "$TREE/.config" && die "simpledrm is on; it hides the last console lines before a reset"

[ "$CONFIG_ONLY" = 1 ] && { log "config written: $TREE/.config"; exit 0; }

log "building Image + dtbs + modules (-j$JOBS)"
make -C "$TREE" -j"$JOBS" ARCH=arm64 CROSS_COMPILE="$CROSS" Image dtbs modules

log "kernel: $TREE/arch/arm64/boot/Image"
log "dtb:    $TREE/arch/arm64/boot/dts/qcom/sm8350-samsung-b2q.dtb"
