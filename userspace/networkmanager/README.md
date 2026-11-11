# NetworkManager: the IPv6 bearer MTU

`0001-wwan-apply-the-MTU-of-an-IPv6-bearer.patch` (against 1.58.1) is the fix in
NetworkManager itself: it applies only an IPv4 bearer config's MTU, so LG U+'s
IPv6-only bearer (MTU 1400) leaves `qmapmux0.0` at 1496 and bigger packets are lost.
It is not built or installed (Noa, 2026-11-11: no big package builds unless absolutely
necessary). The phone gets the same result from `/usr/local/bin/clat-up.sh`, which
sets the link MTU from ModemManager's bearer when the link comes up. The patch is
kept for upstream.
