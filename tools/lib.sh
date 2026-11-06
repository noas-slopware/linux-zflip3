#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
# Shared helpers for the host-side tools. Source this, do not execute it.

set -euo pipefail

REPO_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
warn() { printf 'warning: %s\n' "$*" >&2; }
log() { printf '==> %s\n' "$*" >&2; }

need() {
  local c
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "missing command: $c"
  done
}

# Load the pinned versions and device constants.
load_sources() {
  # shellcheck disable=SC1091
  . "$REPO_ROOT/sources.lock"
}

# die unless the caller has explicitly acknowledged the irreversible prerequisites.
require_unlocked() {
  if [ "${B2Q_UNLOCKED:-0}" != "1" ]; then
    cat >&2 <<'EOF'
Refusing to flash: the device must be unlocked first, and the stock firmware saved.

  1. Settings -> About phone -> Software information: tap Build number 7 times.
  2. Settings -> Developer options: enable OEM unlocking, enable USB debugging.
  3. Reboot to download mode (adb reboot download, or hold Power+VolDown and plug in USB).
     Check the screen: "KG State: Normal" and "OEM LOCK: OFF" after unlocking.
  4. Save the full 4-file stock firmware for your CSC. It is the only way back.

When all of that is true, re-run with: B2Q_UNLOCKED=1 <command>
EOF
    exit 2
  fi
}
