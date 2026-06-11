#!/usr/bin/env bash
# uupl-relay-a / uupl-relay-b smoke test.
#
# Coverage:
#   Connectivity: Modbus :502 and HTTP :8081 for both relays
#   Identity: SNMP sysDescr and sysLocation are unique per device
#   Modbus defaults: protection thresholds match factory values
#   HTTP: web interface returns relay identity; default credentials accepted
#   Force-trip: writing COIL[0]=1 triggers an MQTT trip event; relay auto-reclosing
#
# The force-trip chain subscribes to MQTT before writing the coil so the
# message is not missed. State is restored by the auto-reclose mechanism.
#
# Usage: bash tests/smoke/test_uupl_relay.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENGWS="uupl-eng-ws"
RELAYA="uupl-relay-a"
RELAYB="uupl-relay-b"
MQTT_C="uupl-mqtt"

require_running "$ENGWS"
require_running "$RELAYA"
require_running "$RELAYB"
require_running "$MQTT_C"

RELAYA_IP=$(container_ip "$RELAYA" control)
RELAYB_IP=$(container_ip "$RELAYB" control)
MQTT_IP=$(container_ip "$MQTT_C" control)

# ── Connectivity ──────────────────────────────────────────────────────────────

echo "[uupl-relay] Connectivity"

for ip in "$RELAYA_IP" "$RELAYB_IP"; do
    label=$([ "$ip" = "$RELAYA_IP" ] && echo "relay-a" || echo "relay-b")
    for port in 502 8081; do
        if probe_tcp control "$ip" "$port"; then
            ok "$label port $port reachable from control zone"
        else
            fail "$label port $port not reachable"
        fi
    done
done

# ── SNMP identity ─────────────────────────────────────────────────────────────

echo "[uupl-relay] SNMP identity"

snmp_get_str() {
    local ip="$1" oid_hex="$2"
    docker exec -i "$ENGWS" /venv/bin/python3 - "$ip" "$oid_hex" <<'PY'
import sys, socket
ip  = sys.argv[1]
oid = bytes.fromhex(sys.argv[2])
community = b"public"
comm_tlv  = b"\x04" + bytes([len(community)]) + community
oid_tlv   = b"\x06" + bytes([len(oid)]) + oid
null_tlv  = b"\x05\x00"
varbind   = b"\x30" + bytes([len(oid_tlv)+len(null_tlv)]) + oid_tlv + null_tlv
vblist    = b"\x30" + bytes([len(varbind)]) + varbind
pdu_inner = b"\x02\x04\x00\x00\x00\x01\x02\x01\x00\x02\x01\x00" + vblist
pdu       = b"\xa0" + bytes([len(pdu_inner)]) + pdu_inner
msg_inner = b"\x02\x01\x00" + comm_tlv + pdu
msg       = b"\x30" + bytes([len(msg_inner)]) + msg_inner
s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(3)
s.sendto(msg, (ip, 161))
data, _ = s.recvfrom(4096)
s.close()
pos = data.find(oid)
if pos == -1: sys.exit(1)
after = pos + len(oid)
tag, ln = data[after], data[after+1]
print(data[after+2:after+2+ln].decode('ascii', 'replace') if tag == 0x04 else "")
PY
}

SYSDESCR_OID="2b06010201010100"  # 1.3.6.1.2.1.1.1.0
SYSLOC_OID="2b06010201010600"    # 1.3.6.1.2.1.1.6.0

DESC_A=$(snmp_get_str "$RELAYA_IP" "$SYSDESCR_OID")
DESC_B=$(snmp_get_str "$RELAYB_IP" "$SYSDESCR_OID")
LOC_A=$(snmp_get_str  "$RELAYA_IP" "$SYSLOC_OID")
LOC_B=$(snmp_get_str  "$RELAYB_IP" "$SYSLOC_OID")

assert_contains "$DESC_A" "REL-200a"      "relay-a sysDescr identifies as REL-200a"
assert_contains "$DESC_B" "REL-200b"      "relay-b sysDescr identifies as REL-200b"
assert_contains "$LOC_A"  "Dolly Sisters" "relay-a sysLocation reports Dolly Sisters feeder"
assert_contains "$LOC_B"  "Nap Hill"      "relay-b sysLocation reports Nap Hill feeder"

# ── Modbus defaults ──────────────────────────────────────────────────────────

echo "[uupl-relay] Modbus defaults"

relay_hr() {
    local ip="$1" addr="$2"
    docker exec -i "$ENGWS" /venv/bin/python3 - "$ip" "$addr" <<'PY'
import sys
from pymodbus.client import ModbusTcpClient
c = ModbusTcpClient(sys.argv[1], port=502, timeout=3)
if not c.connect(): print("ERR"); sys.exit(1)
r = c.read_holding_registers(int(sys.argv[2]), 1, slave=1)
c.close()
print(r.registers[0] if not r.isError() else "ERR")
PY
}

for ip in "$RELAYA_IP" "$RELAYB_IP"; do
    label=$([ "$ip" = "$RELAYA_IP" ] && echo "relay-a" || echo "relay-b")
    UV=$(relay_hr "$ip" 0)
    OS=$(relay_hr "$ip" 1)
    OC=$(relay_hr "$ip" 2)
    [ "$UV" = "196"  ] && ok  "$label HR[0] undervoltage threshold = 196 V" \
                         || fail "$label HR[0] undervoltage threshold: expected 196, got '$UV'"
    [ "$OS" = "3300" ] && ok  "$label HR[1] overspeed threshold = 3300 RPM" \
                         || fail "$label HR[1] overspeed threshold: expected 3300, got '$OS'"
    [ "$OC" = "200"  ] && ok  "$label HR[2] overcurrent threshold = 200 A" \
                         || fail "$label HR[2] overcurrent threshold: expected 200, got '$OC'"
done

# ── HTTP interface ─────────────────────────────────────────────────────────────

echo "[uupl-relay] HTTP interface"

for ip in "$RELAYA_IP" "$RELAYB_IP"; do
    label=$([ "$ip" = "$RELAYA_IP" ] && echo "relay-a" || echo "relay-b")

    HTTP_GET=$(in_container "$ENGWS" curl -s --max-time 5 "http://$ip:8081/")
    if [[ "$HTTP_GET" =~ REL-200 ]]; then
        ok "$label GET / returns relay identity page"
    else
        fail "$label GET / did not return expected relay page"
    fi

    LOGIN_CODE=$(in_container "$ENGWS" curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -X POST "http://$ip:8081/login" \
        -d 'username=admin&password=relay1234')
    [ "$LOGIN_CODE" = "302" ] \
        && ok   "$label POST /login with admin/relay1234 returns 302" \
        || fail "$label POST /login: expected 302, got $LOGIN_CODE"
done

# ── Force-trip, MQTT event, auto-reclose ─────────────────────────────────────

echo "[uupl-relay] Force-trip relay-a, MQTT event, auto-reclose"

# Subscribe before writing the coil so the message is never missed.
TRIP_JSON=$(docker exec -i "$ENGWS" /venv/bin/python3 - "$RELAYA_IP" "$MQTT_IP" <<'PY'
import sys, time
import paho.mqtt.client as mqtt
from pymodbus.client import ModbusTcpClient

relay_ip, mqtt_ip = sys.argv[1], sys.argv[2]

got = {}
def on_connect(c, u, f, rc): c.subscribe("uupl/relay/a/trip")
def on_message(c, u, m):
    got["msg"] = m.payload.decode()
    c.disconnect()

mc = mqtt.Client()
mc.on_connect = on_connect
mc.on_message = on_message
mc.connect(mqtt_ip, 1883, 15)
mc.loop_start()
time.sleep(0.5)  # let subscription register before writing the coil

mb = ModbusTcpClient(relay_ip, port=502, timeout=3)
mb.connect()
mb.write_coil(0, True, slave=1)
mb.close()

for _ in range(150):
    if "msg" in got: break
    time.sleep(0.1)
mc.loop_stop()
print(got.get("msg", ""))
PY
)

assert_contains "$TRIP_JSON" '"relay_id": "a"'   "MQTT trip event published for relay-a"
assert_contains "$TRIP_JSON" '"cause": "remote"' "cause logged as remote (external Modbus write)"

# Relay auto-reclosing after RECLOSE_DELAY (10 s); poll COIL[0] returning 0
RECLOSE=$(docker exec -i "$ENGWS" /venv/bin/python3 - "$RELAYA_IP" <<'PY'
import sys, time
from pymodbus.client import ModbusTcpClient
c = ModbusTcpClient(sys.argv[1], port=502, timeout=3)
c.connect()
for _ in range(25):
    r = c.read_coils(0, 1, slave=1)
    if not r.isError() and not r.bits[0]:
        print("RECLOSED")
        break
    time.sleep(1)
else:
    print("TIMEOUT")
c.close()
PY
)

[ "$RECLOSE" = "RECLOSED" ] \
    && ok   "relay-a auto-reclosed after force-trip (COIL[0] cleared within 25 s)" \
    || fail "relay-a did not auto-reclose within 25 s"

summary
