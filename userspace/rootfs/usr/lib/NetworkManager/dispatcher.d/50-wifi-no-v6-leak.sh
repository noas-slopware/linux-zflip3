#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Keep IPv6 off the modem while a Wi-Fi connection is up.
#
# The home network has no IPv6 internet (Korean landlines don't provide it), but the
# LTE bearer does: NetworkManager installs its default route at metric 700 and nothing
# on the Wi-Fi side competes with it, so every application that resolves an AAAA record
# (browsers do) silently sends that traffic over LTE while Wi-Fi sits idle.
#
# While Wi-Fi is up and has no IPv6 default route of its own, install an unreachable
# default at metric 650: above Wi-Fi's own default (600), below the modem's (700).
# On-link prefixes on Wi-Fi keep working, so LAN IPv6 is unaffected; internet IPv6
# fails immediately with ENETUNREACH, and applications fall back to IPv4 over Wi-Fi
# instead of using the modem. When Wi-Fi has a real IPv6 default (another network),
# the blackhole is removed and that route is used. When Wi-Fi goes down, the
# blackhole goes too, and the modem's IPv6 works again.

IFACE="$1"
ACTION="$2"
METRIC=650
BLACKHOLE="unreachable default metric $METRIC"

# Only Wi-Fi devices: the dispatcher also runs for the modem, USB and Tailscale.
[ -e "/sys/class/net/$IFACE/wireless" ] || [ -e "/sys/class/net/$IFACE/phy80211" ] || exit 0

case "$ACTION" in
    up|dhcp6-change|connectivity-change)
        if ip -6 route show default dev "$IFACE" 2>/dev/null | grep -q .; then
            # The Wi-Fi network routes IPv6 itself; don't stand in its way.
            ip -6 route del $BLACKHOLE 2>/dev/null || true
        else
            ip -6 route replace $BLACKHOLE
        fi
        ;;
    down|pre-down)
        ip -6 route del $BLACKHOLE 2>/dev/null || true
        ;;
esac
