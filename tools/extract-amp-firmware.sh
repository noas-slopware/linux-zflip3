#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Copy the CS35L41 speaker protection firmware out of the stock vendor partition,
# renamed for mainline's wm_adsp search path.
#
# Stock ships one Cirrus CSPL firmware per amp in /vendor/firmware, named after its
# downstream dsp-part-name: cs35l40-bot (the bottom speaker, 0x40) and cs35l40-rcv
# (the receiver, 0x41). Mainline looks for
#   cirrus/cs35l41-dsp1-spk-prot-<cirrus,subsystem-id>-<sound-name-prefix>.{wmfw,bin}
# and the DT sets subsystem-id "samsung-b2q" with prefixes Speaker and Earpiece.
#
# The -calib.bin files are stock's factory calibration run, not normal playback, and
# are not copied.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: extract-amp-firmware.sh [--vendor DIR] [--out DIR]

  --vendor DIR  mounted or extracted stock vendor tree holding firmware/
                (default: .cache/fw/super/vfs)
  --out DIR     rootfs overlay to write into (default: out/firmware)
EOF
}

VENDOR="$REPO_ROOT/.cache/fw/super/vfs"
OUT="$REPO_ROOT/out/firmware"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --vendor) VENDOR=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

FW="$OUT/usr/lib/firmware/cirrus"
mkdir -p "$FW"

for pair in bot:speaker rcv:earpiece; do
  stock=${pair%%:*} prefix=${pair#*:}
  for ext in wmfw bin; do
    src="$VENDOR/firmware/cs35l40-$stock-dsp1-spk-prot.$ext"
    [ -f "$src" ] || die "missing $src"
    install -m 0644 "$src" "$FW/cs35l41-dsp1-spk-prot-samsung-b2q-$prefix.$ext"
  done
done

find "$FW" -type f -printf '  %P (%s bytes)\n' >&2
