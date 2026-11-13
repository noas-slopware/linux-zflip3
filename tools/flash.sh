#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Flash images into partitions through Samsung download mode, with heimdall.
#
# The phone may be plugged into another machine (the flash host), and usbip cannot
# carry it reliably, so the images are copied there and flashed natively,
# all in one heimdall session (the phone reboots when the session ends).
# odin4 7.3.0 fails the download-mode handshake on this phone every time; heimdall
# takes raw images and any PIT partition name.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: B2Q_UNLOCKED=1 flash.sh --partition NAME --image IMG [--partition NAME --image IMG ...]

  --partition NAME   boot, recovery, vendor_boot, dtbo or vbmeta
  --image PATH       image for the --partition before it
  --host USER@HOST   flash host the phone is plugged into (default: $B2Q_FLASH_HOST;
                     one of the two, or --local, is required)
  --local            run heimdall on this machine instead
  --dry-run          say what would happen

The phone must already be in download mode (04e8:685d).
EOF
}

PARTS=(); IMAGES=(); HOST=${B2Q_FLASH_HOST:-}; LOCAL=0; DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --partition) PARTS+=("${2:?}"); shift 2 ;;
    --image) IMAGES+=("${2:?}"); shift 2 ;;
    --host) HOST=${2:?}; shift 2 ;;
    --local) LOCAL=1; shift ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ "${#PARTS[@]}" -gt 0 ] && [ "${#PARTS[@]}" = "${#IMAGES[@]}" ] || { usage >&2; exit 1; }
[ "${B2Q_UNLOCKED:-0}" = 1 ] || die "set B2Q_UNLOCKED=1 once the bootloader is unlocked and the stock images are saved"

[ "$LOCAL" = 1 ] || [ -n "$HOST" ] || die "no flash host: give --host, set B2Q_FLASH_HOST or use --local"

if [ "$LOCAL" = 1 ]; then
  run() { bash -c "$1"; }
else
  # The script goes to bash on stdin, whatever the flash host's login shell is.
  run() { ssh "$HOST" bash -s <<<"$1"; }
fi

args=""
for i in "${!PARTS[@]}"; do
  part=${PARTS[$i]}; img=${IMAGES[$i]}
  [ -f "$img" ] || die "no such image: $img"
  case "$part" in
    boot|recovery|vendor_boot|dtbo|vbmeta) ;;
    *) die "unexpected partition: $part" ;;
  esac
  [ "$part" = vbmeta ] && warn "a vbmeta with descriptors gives the unauthorized-software screen; use flags 3 and none"
  sum=$(sha256sum "$img" | cut -d' ' -f1)
  if [ "$LOCAL" = 1 ]; then
    remote=$img
  else
    remote="/tmp/b2q-$part-${sum:0:12}.img"
    if [ "$DRY" = 1 ]; then
      log "would copy $img to $HOST:$remote"
    else
      log "copying $(basename -- "$img") to $HOST:$remote"
      scp -q "$img" "$HOST:$remote"
      [ "$(run "sha256sum $(printf '%q' "$remote") | cut -d' ' -f1")" = "$sum" ] || die "checksum mismatch on $HOST"
    fi
  fi
  log "$part <- $(basename -- "$img") ($sum)"
  args+=" --$(printf '%s' "$part" | tr '[:lower:]' '[:upper:]') $(printf '%q' "$remote")"
done

flash="lsusb -d 04e8:685d >/dev/null || { echo 'phone is not in download mode (04e8:685d)' >&2; exit 2; }
sudo heimdall flash$args"

if [ "$DRY" = 1 ]; then
  log "would run: $flash"
  exit 0
fi

run "$flash"
log "flashed ${PARTS[*]}; the phone reboots on its own"
