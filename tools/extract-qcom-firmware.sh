#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pull Samsung-signed SoC firmware out of the stock firmware tars, for the DT's
# firmware-name entries under qcom/sm8350/Samsung/b2q/.
#
# These images are signed for this phone's secure boot, so linux-firmware's generic
# ones do not load; they sit inside a lz4-compressed FAT image in one of the tars as
# split .mdt/.bNN files and are joined into .mbn with tools/pil-squash.py.
#
#   BL_*.tar.md5  NON-HLOS.bin (--fat default), the "apnhlos" partition
#     a660_zap    GPU zap shader (lets the GPU leave secure mode)
#     ipa_fws     IPA (IP accelerator) firmware
#   CP_*.tar.md5  modem.bin (--fat modem.bin), the CP firmware
#     modem       cellular modem DSP image
#
# Each remote processor's image (adsp, cdsp, slpi, ...) only goes in once that block is
# being brought up, so the default list is what has been enabled so far.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: extract-qcom-firmware.sh TAR [--fat NAME] [--out DIR] [NAME ...]

  TAR         the stock BL_*.tar.md5 or CP_*.tar.md5 (tools/fetch-firmware.sh)
  --fat NAME  FAT image inside it to read (default: NON-HLOS.bin)
  --out DIR   output tree, laid out like / (default: out/firmware)
  NAME        images to extract (default: a660_zap)

  BL tar: --fat NON-HLOS.bin holds a660_zap, ipa_fws.
  CP tar: --fat modem.bin holds modem.
EOF
}

BL=""; FAT="NON-HLOS.bin"; OUT="$REPO_ROOT/out/firmware"; NAMES=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --fat) FAT=${2:?}; shift 2 ;;
    -*) die "unknown option: $1 (try --help)" ;;
    *) if [ -z "$BL" ]; then BL=$1; else NAMES+=("$1"); fi; shift ;;
  esac
done
[ -f "$BL" ] || { usage >&2; exit 1; }
[ "${#NAMES[@]}" -gt 0 ] || NAMES=(a660_zap)
need tar lz4 mcopy mdir python3

WORK=$(mktemp -d "$REPO_ROOT/.cache/qcomfw.XXXXXX")
trap 'rm -rf "$WORK"' EXIT

log "unpacking $FAT from $(basename -- "$BL")"
tar -xf "$BL" -C "$WORK" "$FAT.lz4"
lz4 -dq "$WORK/$FAT.lz4" "$WORK/$FAT"
rm "$WORK/$FAT.lz4"

FW="$OUT/usr/lib/firmware/qcom/sm8350/Samsung/b2q"
mkdir -p "$FW"
for name in "${NAMES[@]}"; do
  files=$(mdir -b -i "$WORK/$FAT" "::/image/$name.*" 2>/dev/null) \
    || die "no image/$name.* in $FAT"
  # shellcheck disable=SC2086
  mcopy -n -i "$WORK/$FAT" $files "$WORK/"
  "$REPO_ROOT/tools/pil-squash.py" "$FW/$name.mbn" "$WORK/$name.mdt"
done

log "wrote:"
find "$FW" -type f -printf '  %P (%s bytes)\n' >&2
