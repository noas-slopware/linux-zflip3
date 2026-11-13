#!/bin/sh
# SPDX-License-Identifier: MIT
#
# Stay on Wi-Fi while suspended, and wake for traffic addressed to us.
#
# Without WoWLAN triggers mac80211 deauthenticates at suspend, so every s2idle drops the
# Wi-Fi connection and anything sent to the phone meanwhile can only arrive over the modem.
# Samsung's stock driver keeps the association and wakes the host for unicast traffic,
# with a packet filter dropping the rest. ath11k has no "any" trigger and no packet
# filter, but it matches patterns: one per address, on our MAC as destination, the
# ethertype and the IP destination (the IPv4 address, or the /64 of each global IPv6
# address). Matching the IP matters: routers that convert multicast to unicast send mDNS
# and the like to our MAC, and a MAC-only pattern woke the phone within a second of every
# suspend. ARP and neighbour solicitations are answered by the firmware (ath11k offloads
# them), so they need no pattern. "disconnect" and "gtk-rekey-failure" wake us when the
# AP drops us, so NetworkManager can reconnect.
#
# The patterns follow the addresses, so they are set again on every address change and
# cleared when Wi-Fi goes down.

IFACE="$1"
ACTION="$2"
MAX_PATTERNS=22

[ -e "/sys/class/net/$IFACE/phy80211" ] || exit 0
command -v iw >/dev/null || exit 0
PHY=$(basename "$(readlink -f "/sys/class/net/$IFACE/phy80211")")

case "$ACTION" in
    up|dhcp4-change|dhcp6-change|reapply|connectivity-change) ;;
    down|pre-down)
        iw phy "$PHY" wowlan disable 2>/dev/null || true
        exit 0
        ;;
    *) exit 0 ;;
esac

MAC=$(cat "/sys/class/net/$IFACE/address")
# n wildcard bytes, colon-separated
wild() { i=0; s=""; while [ "$i" -lt "$1" ]; do s="$s-:"; i=$((i + 1)); done; printf '%s' "$s"; }

patterns=""
count=0

for a in $(ip -4 -o addr show dev "$IFACE" | awk '{split($4, p, "/"); print p[1]}'); do
    ip4=$(echo "$a" | awk -F. '{printf "%02x:%02x:%02x:%02x", $1, $2, $3, $4}')
    # 0-5 destination MAC, 6-11 source, 12-13 0x0800, 14-29 IPv4 header, 30-33 destination
    patterns="$patterns $MAC:$(wild 6)08:00:$(wild 16)$ip4"
    count=$((count + 1))
done

# The /64 of each global address, once each, fully expanded to 8 bytes.
prefixes=$(ip -6 -o addr show dev "$IFACE" scope global | awk '
{
    split($4, p, "/"); a = p[1]
    n = split(a, h, ":"); out = ""; filled = 0
    for (i = 1; i <= n; i++) {
        if (h[i] == "" && !filled && i > 1 && i < n) {
            for (j = 0; j < 8 - (n - 1); j++) out = out "0000"
            filled = 1
        } else if (h[i] != "" || i == 1 || i == n) {
            out = out sprintf("%04s", h[i])
        }
    }
    gsub(/ /, "0", out)
    pfx = substr(out, 1, 16)
    s = ""
    for (i = 1; i <= 16; i += 2) s = s (i > 1 ? ":" : "") substr(pfx, i, 2)
    print s
}' | sort -u)

for pfx in $prefixes; do
    [ "$count" -lt "$MAX_PATTERNS" ] || break
    # 12-13 0x86dd, 14-37 IPv6 header up to the destination, 38-45 the /64
    patterns="$patterns $MAC:$(wild 6)86:dd:$(wild 24)$pfx"
    count=$((count + 1))
done

if [ "$count" -eq 0 ]; then
    iw phy "$PHY" wowlan disable 2>/dev/null || true
    exit 0
fi

# shellcheck disable=SC2086  # one argument per pattern
iw phy "$PHY" wowlan enable disconnect gtk-rekey-failure patterns $patterns
