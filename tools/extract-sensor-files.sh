#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pull the Snapdragon Sensor Core files out of the stock AP tar.
#
# The SLPI (SSC) runs the sensor firmware and asks the AP for its configuration
# through FastRPC, served by hexagonrpcd (see the b2q sensor tree). The files it
# reads are Samsung's:
#
#   vendor:/etc/sensors/config/*.json        sensor definitions and bus config
#   vendor:/etc/sensors/sns_reg_config       where the registry is kept
#   vendor:/lib/rfsa/adsp/libsns_*.so        registry/feature skels for the DSP
#   vendor:/lib/libsns_registry_skel.so      the registry skel itself
#
# They go under /usr/share/qcom/sm8350/Samsung/b2q, the tree hexagonrpcd serves
# with -R. The per-unit calibration registry stays on the phone's persist
# partition and is copied into the tree on first boot.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: extract-sensor-files.sh AP_TAR [--out DIR]

  AP_TAR      the stock AP_*.tar.md5 (tools/fetch-firmware.sh)
  --out DIR   output tree, laid out like / (default: out/firmware)
EOF
}

AP=""; OUT="$REPO_ROOT/out/firmware"
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) OUT=${2:?}; shift 2 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) AP=$1; shift ;;
  esac
done
[ -f "$AP" ] || { usage >&2; exit 1; }
need tar lz4 simg2img lpunpack debugfs

mkdir -p "$REPO_ROOT/.cache"
WORK=$(mktemp -d "$REPO_ROOT/.cache/sensors.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

log "unpacking super from $(basename -- "$AP")"
tar -xf "$AP" -C "$WORK" super.img.lz4
lz4 -dq "$WORK/super.img.lz4" "$WORK/super.sparse"
rm "$WORK/super.img.lz4"
simg2img "$WORK/super.sparse" "$WORK/super.raw"
rm "$WORK/super.sparse"
lpunpack --partition=vendor "$WORK/super.raw" "$WORK" >/dev/null
rm "$WORK/super.raw"

dump() { debugfs -R "dump $1 $2" "$WORK/vendor.img" >/dev/null 2>&1; [ -s "$2" ] || die "no $1 in vendor"; }

TREE="$OUT/usr/share/qcom/sm8350/Samsung/b2q"
rm -rf "$TREE"
mkdir -p "$TREE/dsp/sdsp" "$TREE/sensors/config"

list=$(debugfs -R "ls -p /etc/sensors/config" "$WORK/vendor.img" 2>/dev/null \
	| awk -F/ '$3 ~ /^100/ { print $6 }') || die "no /etc/sensors/config in vendor"

n=0
for f in $list; do
	case "$f" in
	*.json)
		dump "/etc/sensors/config/$f" "$TREE/sensors/config/$f"
		n=$((n + 1))
		;;
	esac
done
[ "$n" -gt 0 ] || die "no JSON configs in /etc/sensors/config"
dump /etc/sensors/sns_reg_config "$TREE/sensors/sns_reg.conf"

for f in lib/rfsa/adsp/libsns_device_mode_skel.so \
	 lib/rfsa/adsp/libsns_low_lat_stream_skel.so \
	 lib/libsns_registry_skel.so; do
	dump "/$f" "$TREE/dsp/sdsp/$(basename -- "$f")"
done

log "wrote:"
find "$TREE" -type f -printf '  %P (%s bytes)\n' >&2
