#!/bin/bash
# SPDX-License-Identifier: MIT
# CLAT on the mobile data link. The link's name is ModemManager's (qmapmux<N>.0,
# N counting modems it has created since it started, so it changes when the SIM
# is reinserted or the modem is reprobed); take it from NetworkManager.
ACTION="$2"

[ -n "$DEVICE_IFACE" ] || exit 0
[ "$(nmcli -g GENERAL.TYPE device show "$DEVICE_IFACE" 2>/dev/null)" = gsm ] || exit 0

case "$ACTION" in
    up)
        /usr/lib/zflip3/clat-up "${DEVICE_IP_IFACE:-$1}"
        ;;
    down)
        /usr/lib/zflip3/clat-down
        ;;
esac
