#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# M0: record what the device says about itself, before anything is modified.
#
# Writes to evidence/device/<timestamp>/ and prints the handful of things that have
# to be read off the screen in download mode.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: evidence.sh [--out DIR]

Needs adb with the device booted into Android and USB debugging authorised.
Everything is read-only: no root, no writes to the device.
EOF
}

STAMP=$(date +%Y%m%d-%H%M%S)
OUT="$REPO_ROOT/evidence/device/$STAMP"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --out) OUT=${2:?--out needs a directory}; shift 2 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

need adb
adb get-state >/dev/null 2>&1 || die "no device: connect USB, unlock, accept the adb prompt"
mkdir -p "$OUT"
log "writing $OUT"

grab() {
  local name=$1; shift
  log "$name"
  adb shell "$@" > "$OUT/$name" 2>&1 || warn "failed: $name"
}

grab getprop.txt      getprop
grab cmdline.txt      cat /proc/cmdline
grab partitions.txt   cat /proc/partitions
grab block-links.txt  ls -l /dev/block/by-name
grab battery.txt      dumpsys battery
grab build.txt        getprop ro.build.fingerprint
grab version.txt      getprop ro.build.version.release
grab oneui.txt        getprop ro.build.version.oneui
grab model.txt        getprop ro.product.model
grab csc.txt          getprop ro.csc.sales_code
grab df.txt           df -h
grab firmware.txt     ls -l /vendor/firmware_mnt/image

# These three decide whether the whole plan is viable, and only the screen shows them.
cat <<'EOF'

Now read these off the phone, in download mode (adb reboot download):

  OEM LOCK     : must become OFF after you enable OEM unlocking and reboot
  KG STATE     : must be Normal. Prenormal means: insert a SIM, connect to the
                 network, do not reboot or reset for 168 hours
  WARRANTY VOID: 0x0 now, 0x1 forever after unlocking. Knox is gone for good.

Record what you see in evidence/device/<timestamp>/download-mode.txt. If OEM unlocking
does not appear in Developer options at all, stop: this plan needs an unlockable device.
EOF
