#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Pull the QCA6390 Wi-Fi/Bluetooth board files out of the stock AP tar.
#
# Mainline uses linux-firmware's QCA6390 firmware (amss.bin, m3.bin), but the board
# data and the Bluetooth NVM are Samsung's, tuned for this phone's RF front end:
#
#   vendor:/firmware/qca6390/bdwlan.elf  -> ath11k/QCA6390/hw2.0/board-2.bin
#   vendor:/firmware/htbtfw20.tlv        -> qca/htbtfw20.tlv
#   vendor:/firmware/htnv20.bin          -> qca/htnv20.bin
#
# They go under /usr/lib/firmware/updates, which the firmware loader searches before
# the linux-firmware package, so nothing a package owns is overwritten.
#
# bdwlan.elf is the file Samsung's cnss2 picks for this unit: board_id 0xff (ath11k
# reports it) and the FEM strap on gpio3 reading low (no .nxp suffix).

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: extract-wcn-firmware.sh AP_TAR [--out DIR]

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
need tar lz4 simg2img lpunpack debugfs python3

WORK=$(mktemp -d "$REPO_ROOT/.cache/wcn.XXXXXX")
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
dump /firmware/qca6390/bdwlan.elf "$WORK/bdwlan.elf"
dump /firmware/htbtfw20.tlv "$WORK/htbtfw20.tlv"
dump /firmware/htnv20.bin "$WORK/htnv20.bin"

FW="$OUT/usr/lib/firmware/updates"
mkdir -p "$FW/ath11k/QCA6390/hw2.0" "$FW/qca"
# The variant entry is what the b2q DT asks for (qcom,calibration-variant); the plain
# entry replaces linux-firmware's generic QCA6390 board data, which would otherwise
# match first, for a kernel booted with another DT.
"$REPO_ROOT/tools/ath11k-board2.py" "$FW/ath11k/QCA6390/hw2.0/board-2.bin" \
  "bus=pci,qmi-chip-id=0,qmi-board-id=255,variant=Samsung_Galaxy_Z_Flip3=$WORK/bdwlan.elf" \
  "bus=pci,qmi-chip-id=0,qmi-board-id=255=$WORK/bdwlan.elf"
install -m644 "$WORK/htbtfw20.tlv" "$WORK/htnv20.bin" "$FW/qca/"

log "wrote:"
find "$OUT" -type f -printf '  %P (%s bytes)\n' >&2
