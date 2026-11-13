#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Write boot images to the phone's partitions from its running Linux, over ssh.
#
# This is the everyday path once U-Boot is installed: no download mode, no key combos.
# Each image is streamed to the phone, written to the partition found by its GPT
# name, read back and compared before anything is reported as done.

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: install-images.sh [--host USER@HOST] [--reboot] PART=IMAGE [PART=IMAGE ...]

  PART=IMAGE      e.g. recovery=out/linux.img boot=out/boot.img
  --host          ssh target, root on the phone (default: $B2Q_SSH; one is required)
  --reboot        reboot the phone afterwards

Example: tools/install-images.sh --host root@phone --reboot recovery=out/linux.img
EOF
}

HOST=${B2Q_SSH:-}; REBOOT=0; PAIRS=()
while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --host) HOST=${2:?}; shift 2 ;;
    --reboot) REBOOT=1; shift ;;
    *=*) PAIRS+=("$1"); shift ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done
[ "${#PAIRS[@]}" -gt 0 ] || { usage >&2; exit 1; }
[ -n "$HOST" ] || die "no ssh target: give --host or set B2Q_SSH"

SSH=(ssh "$HOST")

for pair in "${PAIRS[@]}"; do
  part=${pair%%=*}; img=${pair#*=}
  case "$part" in boot|recovery) ;; *) die "refusing to write $part" ;; esac
  [ -f "$img" ] || die "no such image: $img"
  sum=$(sha256sum "$img" | cut -d' ' -f1)
  size=$(stat -c%s "$img")
  log "$part <- $(basename -- "$img") ($sum)"
  # shellcheck disable=SC2029
  got=$("${SSH[@]}" "set -e
    dev=
    for u in /sys/class/block/*/uevent; do
      grep -qx PARTNAME=$part \"\$u\" && dev=/dev/\$(sed -n 's/^DEVNAME=//p' \"\$u\") && break
    done
    [ -n \"\$dev\" ] || { echo 'no $part partition' >&2; exit 1; }
    [ \$(( \$(cat /sys/class/block/\${dev#/dev/}/size) * 512 )) -ge $size ] || { echo 'image larger than $part' >&2; exit 1; }
    dd of=\"\$dev\" bs=1M iflag=fullblock conv=fsync status=none
    head -c $size \"\$dev\" | sha256sum | cut -d' ' -f1" < "$img")
  [ "$got" = "$sum" ] || die "$part reads back as $got, not $sum"
  log "$part verified"
done

if [ "$REBOOT" = 1 ]; then
  log "rebooting"
  "${SSH[@]}" 'systemctl reboot' || true
fi
