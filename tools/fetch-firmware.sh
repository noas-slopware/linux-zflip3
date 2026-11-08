#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# M0: download the stock firmware that tools/extract-firmware.sh then unpacks.
#
# Uses samloader (the Rust one, github.com/topjohnwu/samloader-rs), which speaks the
# current "Smart" FUS protocol. The archived Python samloader returns 403 for every
# model/region now, so do not reach for it.
#
# The firmware is the only way back if the phone ends up unbootable. Keep it.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"
load_sources

usage() {
  cat <<'EOF'
usage: fetch-firmware.sh [options]

  --model M      device model (default: B2Q_MODEL from sources.lock)
  --region R     CSC region (default: LUC — the sales code this phone reports)
  --version V    firmware version string; omit for the latest
  --out DIR      where to put the tar.md5 files (default: .cache/fw)
  --threads N    parallel connections (default 8)
  --list         only print available versions and exit
  --samloader P  path to the samloader binary (default: samloader on PATH)

Installing samloader:
  cargo install --git https://github.com/topjohnwu/samloader-rs --locked samloader
Then point extract-firmware.sh at the AP tar it writes.
EOF
}

MODEL=${B2Q_MODEL:-SM-F711N}
REGION="LUC"
VERSION=""
OUT="$REPO_ROOT/.cache/fw"
THREADS=8
LIST=0
SAMLOADER=$(command -v samloader || echo "$HOME/.cargo/bin/samloader")

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --model) MODEL=${2:?}; shift 2 ;;
    --region) REGION=${2:?}; shift 2 ;;
    --version) VERSION=${2:?}; shift 2 ;;
    --out) OUT=${2:?}; shift 2 ;;
    --threads) THREADS=${2:?}; shift 2 ;;
    --list) LIST=1; shift ;;
    --samloader) SAMLOADER=${2:?}; shift 2 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -x "$SAMLOADER" ] || die "no samloader at $SAMLOADER (see --help for the cargo install line)"
mkdir -p "$OUT"

if [ "$LIST" = 1 ]; then
  exec "$SAMLOADER" check-update -m "$MODEL" -r "$REGION" -a
fi

args=(download -m "$MODEL" -r "$REGION" -d "$OUT" -j "$THREADS")
[ -n "$VERSION" ] && args+=(-v "$VERSION")
log "samloader ${args[*]}"
"$SAMLOADER" "${args[@]}"

log "downloaded into $OUT:"
ls -lh "$OUT" | sed 's/^/    /'

cat <<EOF

Next:
  tools/extract-firmware.sh $OUT/AP_*.tar.md5
EOF
