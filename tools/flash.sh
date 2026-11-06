#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Flash one image into one partition through Samsung download mode.
#
# Odin matches partitions by the file name inside the tar, so the member has to be
# named after the partition (boot.img, recovery.img, dtbo.img, vbmeta.img).

set -euo pipefail
. "$(dirname -- "${BASH_SOURCE[0]}")/lib.sh"

usage() {
  cat <<'EOF'
usage: B2Q_UNLOCKED=1 flash.sh --image IMG --partition NAME [options]

  --image PATH       image to flash (required)
  --partition NAME   boot, recovery, dtbo or vbmeta (default: recovery)
  --tar-only         write the tar and stop; do not invoke the flasher
  --flasher CMD      odin4 (default) or heimdall
  --dry-run          say what would happen
EOF
}

IMAGE=""; PART=recovery; TAR_ONLY=0; FLASHER=odin4; DRY=0

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --image) IMAGE=${2:?}; shift 2 ;;
    --partition) PART=${2:?}; shift 2 ;;
    --tar-only) TAR_ONLY=1; shift ;;
    --flasher) FLASHER=${2:?}; shift 2 ;;
    --dry-run) DRY=1; shift ;;
    *) die "unknown option: $1 (try --help)" ;;
  esac
done

[ -n "$IMAGE" ] || { usage >&2; exit 1; }
[ -f "$IMAGE" ] || die "no such image: $IMAGE"
case "$PART" in
  boot|recovery|dtbo|vbmeta) ;;
  *) die "unexpected partition: $PART" ;;
esac
if [ "$PART" = "vbmeta" ]; then
  warn "flashing vbmeta disables AVB; only do this if ABL refuses a valid boot image"
fi

require_unlocked
need tar

TAR="$REPO_ROOT/out/flash-$PART.tar"
mkdir -p "$(dirname -- "$TAR")"
log "writing $TAR ($PART.img)"
tar -cf "$TAR" --transform "s,^.*/,," --transform "s,^${PART}\.img.*,${PART}.img," -C "$(dirname -- "$IMAGE")" "$(basename -- "$IMAGE")"
tar -tf "$TAR" | sed 's/^/    /'

if [ "$TAR_ONLY" = 1 ]; then
  log "stopping after the tar (--tar-only)"
  exit 0
fi

if [ "$DRY" = 1 ]; then
  log "would run: $FLASHER -a $TAR"
  exit 0
fi

if ! command -v "$FLASHER" >/dev/null 2>&1; then
  cat >&2 <<EOF
error: $FLASHER is not installed.

  odin4 (AUR: odin4, or github.com/Llucs/odin4) is the reliable choice for SM8350-class
  Samsungs. Heimdall's protocol support is spotty on these.

The tar is ready:
  $TAR

Put the phone in download mode (adb reboot download, or Power+VolDown then plug in USB)
and run:
  $FLASHER -a $TAR
EOF
  exit 3
fi

log "flashing $PART through $FLASHER"
"$FLASHER" -a "$TAR"

cat <<EOF

Flashed $PART.img.
  adb reboot recovery   -> boots the new recovery image (works while Android is in boot)
  adb reboot            -> back to Android
If it resets back to the Samsung logo, see docs/boot-chain.md (vbmeta, board string).
EOF
