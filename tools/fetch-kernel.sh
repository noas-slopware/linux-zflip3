#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Fetch the pinned mainline base, verify it, and optionally apply patches/linux/.
#
# Downloads into .cache/ so nothing large lands in git. The tarball is checked
# against cdn.kernel.org's sha256sums.asc for the series directory.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
load_sources

usage() {
  cat <<'EOF'
usage: fetch-kernel.sh [options]

  --version VER     kernel version (default: LINUX_VERSION from sources.lock)
  --series SERIES   kernel.org series directory (default: LINUX_SERIES)
  --apply           apply patches/linux/*.patch in order
  --build           build after fetching (needs --cross or an aarch64 host)
  --cross PREFIX    cross compiler prefix, e.g. aarch64-linux-gnu-
  --config FILE     kernel config to install as .config before building
  --jobs N          make -j (default: nproc)
  --clean           remove the cached tarball first

Nothing is built by default: fetch and verify only.
EOF
}

VERSION=""; SERIES=""; APPLY=0; BUILD=0; CROSS=""; CONFIG=""; JOBS=$(nproc); CLEAN=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --version) VERSION=${2:?}; shift 2 ;;
    --series) SERIES=${2:?}; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --build) BUILD=1; shift ;;
    --cross) CROSS=${2:?}; shift 2 ;;
    --config) CONFIG=${2:?}; shift 2 ;;
    --jobs) JOBS=${2:?}; shift 2 ;;
    --clean) CLEAN=1; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

VERSION=${VERSION:-$LINUX_VERSION}
SERIES=${SERIES:-$LINUX_SERIES}

CACHE="$REPO_ROOT/.cache"
TARBALL="linux-$VERSION.tar.xz"
URL="https://cdn.kernel.org/pub/linux/kernel/$SERIES/$TARBALL"
SRC="$CACHE/linux-$VERSION"

need curl tar xz sha256sum
mkdir -p "$CACHE"
[ "$CLEAN" = 1 ] && rm -f "$CACHE/$TARBALL" "$CACHE/sha256sums.asc"

if [ ! -f "$CACHE/$TARBALL" ]; then
  log "downloading $URL"
  curl -fL --retry 3 -o "$CACHE/$TARBALL.part" "$URL"
  mv "$CACHE/$TARBALL.part" "$CACHE/$TARBALL"
fi

log "verifying against $SERIES/sha256sums.asc"
curl -fsSL -o "$CACHE/sha256sums.asc" "https://cdn.kernel.org/pub/linux/kernel/$SERIES/sha256sums.asc"
want=$(grep -F " $TARBALL" "$CACHE/sha256sums.asc" | awk '{print $1}' | head -n1)
[ -n "$want" ] || die "no checksum for $TARBALL in sha256sums.asc"
got=$(sha256sum "$CACHE/$TARBALL" | cut -d' ' -f1)
[ "$want" = "$got" ] || die "checksum mismatch: want $want got $got"
log "checksum ok: $got"

if [ ! -d "$SRC" ]; then
  log "extracting to $SRC"
  tar -C "$CACHE" -xf "$CACHE/$TARBALL"
else
  log "already extracted: $SRC"
fi

if [ "$APPLY" = 1 ]; then
  mapfile -t patches < <(find "$REPO_ROOT/patches/linux" -maxdepth 1 -name '[0-9][0-9][0-9][0-9]-*.patch' | sort)
  if [ "${#patches[@]}" -eq 0 ]; then
    warn "no patches in patches/linux/ yet; nothing applied"
  else
    for p in "${patches[@]}"; do
      log "applying $(basename "$p")"
      git -C "$SRC" apply --index "$p" 2>/dev/null || patch -d "$SRC" -p1 -i "$p"
    done
  fi
fi

if [ "$BUILD" = 1 ]; then
  shopt -s nullglob
  dtbs=("$SRC"/arch/arm64/boot/dts/qcom/*samsung-b2q*)
  shopt -u nullglob
  [ "${#dtbs[@]}" -gt 0 ] || warn "no b2q device tree in the tree yet; the build will not run on the phone"
  [ -n "$CONFIG" ] && install -m644 "$CONFIG" "$SRC/.config"
  log "building with ${CROSS:-native} toolchain"
  make -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" -j"$JOBS" Image dtbs
fi

echo
log "tree: $SRC"
cat <<EOF

For a boot image:
  tools/bootimg.sh --kernel $SRC/arch/arm64/boot/Image \\
                   --dtb    $SRC/arch/arm64/boot/dts/qcom/<board>.dtb \\
                   --ramdisk out/initramfs.cpio.gz --out out/recovery.img
EOF
