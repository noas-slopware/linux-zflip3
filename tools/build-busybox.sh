#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Build the static aarch64 busybox the initramfs runs on.
#
# Alpine's busybox-static leaves out telnetd and udhcpd, which the USB network shell
# needs, so we build defconfig ourselves. Two defconfig symbols do not build here:
# TC (fails against current kernel headers) and the SHA hardware acceleration
# (x86 only, but defconfig enables it on every architecture).

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
load_sources

usage() {
  cat <<'EOF2'
usage: build-busybox.sh [--cross PREFIX] [--out PATH]

  --cross PREFIX  cross compiler prefix (default: aarch64-linux-gnu-)
  --out PATH      where to put the binary (default: out/busybox)
EOF2
}

CROSS="aarch64-linux-gnu-"
OUT="$REPO_ROOT/out/busybox"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --cross) CROSS=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

need curl tar make sha256sum "${CROSS}gcc"

DIR="$REPO_ROOT/.cache/busybox"
TARBALL="$DIR/busybox-$BUSYBOX_VERSION.tar.bz2"
SRC="$DIR/busybox-$BUSYBOX_VERSION"
mkdir -p "$DIR"

if [ ! -f "$TARBALL" ]; then
  log "fetching busybox $BUSYBOX_VERSION"
  curl -fsSL -o "$TARBALL.part" "https://busybox.net/downloads/busybox-$BUSYBOX_VERSION.tar.bz2"
  mv "$TARBALL.part" "$TARBALL"
fi
echo "$BUSYBOX_SHA256  $TARBALL" | sha256sum -c --quiet - || die "checksum mismatch: $TARBALL"

rm -rf "$SRC"
tar -xjf "$TARBALL" -C "$DIR"

make -s -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" defconfig >/dev/null 2>&1
sed -i -e 's/^# CONFIG_STATIC is not set$/CONFIG_STATIC=y/' \
       -e 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' \
       -e 's/^CONFIG_SHA1_HWACCEL=y$/# CONFIG_SHA1_HWACCEL is not set/' \
       -e 's/^CONFIG_SHA256_HWACCEL=y$/# CONFIG_SHA256_HWACCEL is not set/' "$SRC/.config"
make -s -C "$SRC" ARCH=arm64 CROSS_COMPILE="$CROSS" oldconfig </dev/null >/dev/null 2>&1
for sym in STATIC TELNETD UDHCPD SWITCH_ROOT; do
  grep -q "^CONFIG_$sym=y" "$SRC/.config" || die "busybox CONFIG_$sym is not set"
done

log "building busybox (-j$(nproc))"
make -s -C "$SRC" -j"$(nproc)" ARCH=arm64 CROSS_COMPILE="$CROSS" >/dev/null 2>"$DIR/build.log" \
  || { tail -20 "$DIR/build.log" >&2; die "busybox build failed (log: $DIR/build.log)"; }

mkdir -p "$(dirname -- "$OUT")"
install -m755 "$SRC/busybox" "$OUT"
log "$OUT"
