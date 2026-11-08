#!/bin/bash
set -e

IFACE="qmapmux0.0"
PREFIX=$(ip -6 addr show dev $IFACE scope global 2>/dev/null | grep inet6 | head -n1 | awk '{print $2}' | cut -d/ -f1 | cut -d: -f1-4)
if [ -z "$PREFIX" ]; then
    echo "No global IPv6 on $IFACE, cannot start CLAT"
    exit 0
fi

CLAT_IP6="${PREFIX}::464"
echo "Starting CLAT with prefix $PREFIX (CLAT IPv6: $CLAT_IP6)"

mkdir -p /run/tayga
cat << TCONF > /run/tayga/tayga.conf
tun-device clat0
ipv4-addr 192.0.0.1
ipv6-addr 2001:db8::1
prefix 64:ff9b::/96
map 192.0.0.4 $CLAT_IP6
data-dir /tmp
TCONF

ip tuntap add dev clat0 mode tun 2>/dev/null || true
ip link set clat0 up
ip addr add 192.0.0.4/32 dev clat0 2>/dev/null || true
ip route replace 192.0.0.1 dev clat0
ip -6 route replace $CLAT_IP6 dev clat0

sysctl -w net.ipv6.conf.all.forwarding=1 >/dev/null
sysctl -w net.ipv6.conf.clat0.forwarding=1 >/dev/null

killall tayga 2>/dev/null || true
tayga -c /run/tayga/tayga.conf

# Add default IPv4 route with metric 700 (behind WiFi metric 600)
ip route replace default via 192.0.0.1 dev clat0 metric 700
echo "CLAT up and running"
