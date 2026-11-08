#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Ask the phone whether it is willing to boot an unofficial image yet.
#
# The flash itself always succeeds; what this checks is the boot-side gate. On this unit
# `knox.kg.state = Checking` is still blocking, which was established the expensive way:
# stock boot.img boots, our identically-packaged boot.img is refused and the device falls
# back to download mode.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

HOST=${B2Q_HOST:-yuifunami@192.168.0.6}
SERIAL=${B2Q_SERIAL:-}

usage() {
  cat <<'EOF'
usage: gate.sh [--host USER@HOST] [--serial SERIAL]

Reads knox.kg.state, ro.boot.flash.locked and ro.boot.verifiedbootstate over adb on the
host the phone is plugged into, and says whether a flash is worth attempting.
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --host) HOST=${2:?}; shift 2 ;;
    --serial) SERIAL=${2:?}; shift 2 ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done
[ -n "$SERIAL" ] || die "no adb serial: set B2Q_SERIAL or pass --serial ('adb devices -l' on the host lists it)"

q() {
  ssh -o BatchMode=yes "$HOST" "sg plugdev -c 'adb -s $SERIAL shell getprop $1'" 2>/dev/null | tr -d '\r' | tail -1
}

state=$(q knox.kg.state)
locked=$(q ro.boot.flash.locked)
vb=$(q ro.boot.verifiedbootstate)

printf 'kg.state          %s\n' "${state:-unreachable}"
printf 'flash.locked      %s\n' "${locked:-unreachable}"
printf 'verifiedbootstate %s\n' "${vb:-unreachable}"
echo

case "$state" in
  Completed|Normal)
    if [ "$locked" = "0" ]; then
      echo "READY: flash boot + vendor_boot."
    else
      echo "LOCKED: flash.locked is $locked; unlock again in download mode first."
    fi
    ;;
  Checking|Prenormal|"")
    echo "NOT READY: the bootloader refuses unofficial images while KG is '${state:-unknown}'."
    echo "Keep the phone booted, online, and unreset. See docs/gate.md."
    ;;
  *)
    echo "UNKNOWN state '$state'; see docs/gate.md."
    ;;
esac
