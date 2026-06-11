#!/usr/bin/env bash
# hex-turbine-plc smoke test.
#
# Connectivity, protocol identity, and basic liveness for the turbine PLC.
# All probes run from inside uupl-eng-ws, the dual-homed engineering workstation
# that ships pymodbus, paho-mqtt, and Python — the same vantage point an
# attacker with a shell there would have.
#
# Coverage:
#   Connectivity: Modbus :502, IEC-104 :2404, DNP3 :20000, OPC-UA :4840
#   SNMP: sysDescr identifies as HEX-CPU-4000 Turbine PLC
#   Modbus: turbine is running (RPM > 0); governor setpoint readable
#   IEC-104: STARTDT handshake returns STARTDT_CON
#
# Usage: bash tests/smoke/test_hex_turbine_plc.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENGWS="uupl-eng-ws"
PLC="hex-turbine-plc"
PLC_IP="10.10.3.21"

require_running "$ENGWS"
require_running "$PLC"

# ── Connectivity ──────────────────────────────────────────────────────────────

echo "[hex-turbine-plc] Connectivity"

for port in 502 2404 20000 4840; do
    if probe_tcp control "$PLC_IP" "$port"; then
        ok "port $port open on hex-turbine-plc"
    else
        fail "port $port not reachable from control zone"
    fi
done

# ── SNMP identity ─────────────────────────────────────────────────────────────

echo "[hex-turbine-plc] SNMP identity"

SNMP_DESC=$(docker exec -i "$ENGWS" /venv/bin/python3 - "$PLC_IP" <<'PY'
import sys, socket
ip = sys.argv[1]
oid = bytes([0x2b, 0x06, 0x01, 0x02, 0x01, 0x01, 0x01, 0x00])  # 1.3.6.1.2.1.1.1.0
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
if pos == -1:
    sys.exit(1)
after = pos + len(oid)
tag, ln = data[after], data[after+1]
print(data[after+2:after+2+ln].decode('ascii', 'replace') if tag == 0x04 else "")
PY
)

assert_contains "$SNMP_DESC" "HEX-CPU-4000" "sysDescr identifies as HEX-CPU-4000"
assert_contains "$SNMP_DESC" "Turbine PLC"  "sysDescr carries device role"

# ── Modbus liveness ──────────────────────────────────────────────────────────

echo "[hex-turbine-plc] Modbus liveness"

PLC_RPM=$(docker exec -i "$ENGWS" /venv/bin/python3 - "$PLC_IP" <<'PY'
import sys
from pymodbus.client import ModbusTcpClient
c = ModbusTcpClient(sys.argv[1], port=502, timeout=3)
if not c.connect(): print("ERR"); sys.exit(1)
r = c.read_input_registers(0, 1, slave=1)
c.close()
print(r.registers[0] if not r.isError() else "ERR")
PY
)

if [[ "$PLC_RPM" =~ ^[0-9]+$ ]] && [ "$PLC_RPM" -gt 0 ]; then
    ok "Modbus IR[0] (RPM) = $PLC_RPM, turbine running"
else
    fail "Modbus IR[0] (RPM) returned '$PLC_RPM' — expected a positive integer"
fi

PLC_FUELV=$(docker exec -i "$ENGWS" /venv/bin/python3 - "$PLC_IP" <<'PY'
import sys
from pymodbus.client import ModbusTcpClient
c = ModbusTcpClient(sys.argv[1], port=502, timeout=3)
if not c.connect(): print("ERR"); sys.exit(1)
r = c.read_holding_registers(1, 1, slave=1)
c.close()
print(r.registers[0] if not r.isError() else "ERR")
PY
)

if [[ "$PLC_FUELV" =~ ^[0-9]+$ ]] && [ "$PLC_FUELV" -gt 0 ]; then
    ok "Modbus HR[1] (fuel valve command) = $PLC_FUELV%, governor active"
else
    fail "Modbus HR[1] (fuel valve) returned '$PLC_FUELV' — expected positive integer"
fi

# ── IEC-104 STARTDT handshake ─────────────────────────────────────────────────

echo "[hex-turbine-plc] IEC-104 STARTDT handshake"

IEC104_RESP=$(docker exec -i "$ENGWS" /venv/bin/python3 - "$PLC_IP" <<'PY'
import sys, socket
ip = sys.argv[1]
startdt_act = bytes([0x68, 0x04, 0x07, 0x00, 0x00, 0x00])
s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
s.settimeout(5)
s.connect((ip, 2404))
s.sendall(startdt_act)
data = s.recv(32)
s.close()
print(data.hex())
PY
)

# STARTDT_CON = 68 04 0b 00 00 00
if [[ "$IEC104_RESP" == 68040b000000* ]]; then
    ok "IEC-104 STARTDT_CON received (68 04 0b 00 00 00)"
else
    fail "IEC-104 STARTDT_CON not received (got '$IEC104_RESP')"
fi

summary
