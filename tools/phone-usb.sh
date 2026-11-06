#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Find the phone on the USB/IP host and attach it here, refusing lookalikes.
#
# `usbip-helper` only knows busids, and a Samsung printer also answers to 04e8. This
# wrapper reads the remote device list, keeps only phone-class devices, and re-reads the
# busid every time, because it changes on every re-enumeration and even on a cable swap.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: phone-usb.sh [status|bind|unbind|wait]

  status  list 04e8 devices on the USB/IP host and classify them
  bind    attach the phone (refuses the printer and anything unrecognised)
  unbind  detach it again
  wait    poll until the phone shows up, then bind (120 s)

Samsung reuses USB IDs across models, so classification is by the usb.ids description as
well: anything 04e8 whose description mentions USB debugging or tethering is an Android
device. 04e8:3321 is the Samsung M2020 printer on this desk and is refused by id.
Observed so far: 04e8:6860, 04e8:6864 (phone, Android), 04e8:685d (download mode).
EOF
}

# busid id description
list_devices() {
  usbip-helper list 2>/dev/null | awk '
    /busid/ && match($0, /\(([0-9a-f]{4}:[0-9a-f]{4})\)/) {
      busid = $3; gsub(/[()]/, "", busid)
      id = substr($0, RSTART + 1, RLENGTH - 2)
      desc = ""
      if (getline > 0) desc = $0
      print busid, id, desc
    }
  '
}

classify() {
  local id=$1 desc=$2
  case "$id" in
    04e8:3321) echo "PRINTER, not the phone" ;;
    04e8:685d) echo "phone, download mode" ;;
    04e8:*)
      case "$desc" in
        *"USB debugging"*|*tethering*|*MTP*|*Galaxy*) echo "phone, Android" ;;
        *) echo "04e8 but unrecognised" ;;
      esac
      ;;
    *) echo "unknown" ;;
  esac
}

phone_line() {
  local busid id desc
  while read -r busid id desc; do
    [ -n "$busid" ] || continue
    case "$(classify "$id" "$desc")" in
      "phone"*) printf '%s %s %s\n' "$busid" "$id" "$desc" ;;
    esac
  done < <(list_devices)
}

cmd=${1:-status}

case "$cmd" in
  -h|--help) usage; exit 0 ;;
  status)
    found=0
    while read -r busid id desc; do
      [ -n "$busid" ] || continue
      found=1
      printf '%-8s %-11s %s\n' "$busid" "$id" "$(classify "$id" "$desc")"
    done < <(list_devices)
    [ "$found" = 1 ] || echo "no 04e8 device on the USB/IP host"
    ;;
  bind)
    read -r busid id desc < <(phone_line) || true
    [ -n "${busid:-}" ] || die "no phone on the USB/IP host (try: $0 status)"
    log "binding $busid ($id, $desc)"
    usbip-helper bind "$busid"
    sleep 2
    adb devices -l
    ;;
  unbind)
    read -r busid _ _ < <(phone_line) || true
    [ -n "${busid:-}" ] || die "no phone attached to detach"
    log "unbinding $busid"
    usbip-helper unbind "$busid"
    ;;
  wait)
    for _ in $(seq 1 60); do
      read -r busid _ _ < <(phone_line) || true
      [ -n "${busid:-}" ] || { sleep 2; continue; }
      log "phone appeared on $busid"
      exec "$0" bind
    done
    die "phone did not appear after 120 s; check the cable, the port, and USB mode on the phone"
    ;;
  *) usage >&2; exit 1 ;;
esac
