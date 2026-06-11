#!/usr/bin/env bash
# Control zone process-level smoke test.
#
# Unlike the facade tests, this does not check banners or file contents. It
# perturbs the live turbine and asserts that the consequence propagates through
# the plant, proving the control zone behaves as one interconnected system
# rather than a set of isolated vulnerable containers.
#
# Chains exercised:
#   A. MQTT mirrors Modbus      PLC telemetry on uupl/turbine/telemetry tracks
#                               the live input registers (two surfaces agree)
#   B. Cooling loss -> heat     HR[2]=0 (cooling pump) raises turbine temperature
#   C. Breaker open -> feeder   tripping uupl-breaker-a collapses feeder A voltage
#                               and raises the undervoltage alarm, via the PLC's
#                               actuator-sync loop
#   D. Setpoint -> overspeed    raising the governor setpoint above the trip line
#                               drives RPM past 3300, latches e-stop, cuts fuel
#
# Origin of the probes is uupl-eng-ws (10.10.3.100, dual-homed into control). It
# ships pymodbus and paho-mqtt for the engineer's job, which is exactly what an
# attacker with a shell there reaches for. No test-only tooling is added.
#
# The test mutates shared process state and restores it at the end of each
# chain. It is slow by smoke-test standards (physics has to settle); budget a
# couple of minutes.
#
# Usage: bash tests/smoke/test_control_zone_process.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENGWS="uupl-eng-ws"
PLC="hex-turbine-plc"
BRKA="uupl-breaker-a"
MQTT="uupl-mqtt"
RELAYA="uupl-relay-a"

require_running "$ENGWS"
require_running "$PLC"
require_running "$BRKA"
require_running "$MQTT"
require_running "$RELAYA"

PLC_IP=$(container_ip "$PLC" control)
BRKA_IP=$(container_ip "$BRKA" control)
MQTT_IP=$(container_ip "$MQTT" control)
RELAYA_IP=$(container_ip "$RELAYA" control)
FUELV_IP="10.10.3.51"

# ── Modbus helper ──────────────────────────────────────────────────────────────
# Runs the shipped pymodbus from inside eng-ws. Reads echo the integer value;
# writes echo OK. Non-zero exit on any Modbus or transport error.
#   mb <host> read  <fc> <addr>
#   mb <host> write <fc> <addr> <value>     fc: 1=coil, 3=holding, 4=input
mb() {
    docker exec -i "$ENGWS" /venv/bin/python3 - "$@" <<'PY'
import sys
from pymodbus.client import ModbusTcpClient
host, op, fc, addr = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
val = int(sys.argv[5]) if len(sys.argv) > 5 else None
c = ModbusTcpClient(host, port=502, timeout=3)
if not c.connect():
    print("ERR connect"); sys.exit(1)
try:
    if op == "read":
        if fc == 1:
            r = c.read_coils(addr, 1, slave=1)
        elif fc == 3:
            r = c.read_holding_registers(addr, 1, slave=1)
        else:
            r = c.read_input_registers(addr, 1, slave=1)
        if r.isError():
            print("ERR", r); sys.exit(1)
        print(int(r.bits[0]) if fc == 1 else int(r.registers[0]))
    else:
        r = c.write_coil(addr, bool(val), slave=1) if fc == 1 \
            else c.write_register(addr, val, slave=1)
        if r.isError():
            print("ERR", r); sys.exit(1)
        print("OK")
finally:
    c.close()
PY
}

ir() { mb "$PLC_IP" read 4 "$1"; }   # input register
co() { mb "$PLC_IP" read 1 "$1"; }   # coil

# Register/coil map (see plc_server.py)
IR_RPM=0; IR_TEMP=1; IR_V_A=3; IR_POWER=8
CO_ESTOP=0; CO_ALM_SPEED=1; CO_ALM_VOLT=4; CO_BREAKER_A=5
HR_SETPOINT=0; HR_COOLING=2
RPM_TRIP=3300; TEMP_TRIP=490

# Poll a reader until its integer output satisfies a comparison, or timeout.
#   poll_num <timeout-s> <reader-cmd> <op> <threshold>
# op is a test(1) integer operator: -gt -lt -ge -le -eq. Echoes the last value.
poll_num() {
    local t="$1" reader="$2" op="$3" thr="$4" i=0 v=""
    while [ "$i" -lt "$t" ]; do
        v=$($reader 2>/dev/null)
        if [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" "$op" "$thr" ]; then
            echo "$v"; return 0
        fi
        sleep 2; i=$((i + 2))
    done
    echo "$v"; return 1
}

# Wait for the plant to be running and stable before perturbing it.
wait_steady() {
    echo "[control] waiting for turbine to reach running speed..."
    if ! poll_num 90 "ir $IR_RPM" -gt 2700 >/dev/null; then
        fail "turbine did not reach running speed (RPM>2700) within 90s; aborting"
        summary; exit 1
    fi
}

# ── Chain A: MQTT telemetry mirrors the Modbus input registers ──────────────────

echo "[control] Chain A: MQTT telemetry mirrors Modbus"

wait_steady

# Grab one telemetry message off the broker using the shipped paho-mqtt client.
MQTT_JSON="$(docker exec -i "$ENGWS" /venv/bin/python3 - "$MQTT_IP" <<'PY'
import sys, paho.mqtt.client as mqtt
host = sys.argv[1]
got = {}
def on_connect(c, u, f, rc): c.subscribe("uupl/turbine/telemetry")
def on_message(c, u, m): got["p"] = m.payload.decode(); c.disconnect()
cl = mqtt.Client()
cl.on_connect = on_connect
cl.on_message = on_message
cl.connect(host, 1883, 15)
cl.loop_start()
import time
for _ in range(150):
    if "p" in got: break
    time.sleep(0.1)
cl.loop_stop()
print(got.get("p", ""))
PY
)"

assert_contains "$MQTT_JSON" '"rpm"'   "telemetry published on uupl/turbine/telemetry (anonymous subscribe)"
assert_contains "$MQTT_JSON" '"estop"' "telemetry payload carries the e-stop state"

MQTT_RPM=$(sed -n 's/.*"rpm":[[:space:]]*\([0-9]*\).*/\1/p' <<< "$MQTT_JSON")
MODBUS_RPM=$(ir $IR_RPM)
if [[ "$MQTT_RPM" =~ ^[0-9]+$ ]] && [[ "$MODBUS_RPM" =~ ^[0-9]+$ ]]; then
    DIFF=$(( MQTT_RPM > MODBUS_RPM ? MQTT_RPM - MODBUS_RPM : MODBUS_RPM - MQTT_RPM ))
    if [ "$MQTT_RPM" -gt 2000 ] && [ "$DIFF" -lt 600 ]; then
        ok "MQTT RPM ($MQTT_RPM) tracks Modbus RPM ($MODBUS_RPM); two surfaces agree"
    else
        fail "MQTT RPM ($MQTT_RPM) and Modbus RPM ($MODBUS_RPM) disagree (diff $DIFF)"
    fi
else
    fail "could not parse RPM from MQTT ('$MQTT_RPM') or Modbus ('$MODBUS_RPM')"
fi

# ── Chain B: cutting cooling raises turbine temperature ─────────────────────────

echo "[control] Chain B: cooling loss raises temperature"

wait_steady
TEMP_BASE=$(ir $IR_TEMP)
echo "[control] baseline temperature ${TEMP_BASE}C; closing cooling pump (HR[2]=0)"
mb "$PLC_IP" write 3 $HR_COOLING 0 >/dev/null

TEMP_HOT=$(poll_num 40 "ir $IR_TEMP" -ge $((TEMP_BASE + 25)))
if [ "$?" -eq 0 ]; then
    ok "loss of cooling raised temperature ${TEMP_BASE}C -> ${TEMP_HOT}C"
else
    fail "temperature did not rise after cooling loss (baseline ${TEMP_BASE}C, last ${TEMP_HOT}C)"
fi
if [ "${TEMP_HOT:-0}" -lt "$TEMP_TRIP" ]; then
    ok "temperature stayed below the overtemp trip line (${TEMP_HOT}C < ${TEMP_TRIP}C)"
else
    fail "temperature crossed the trip line unexpectedly (${TEMP_HOT}C)"
fi

echo "[control] restoring cooling (HR[2]=100)"
mb "$PLC_IP" write 3 $HR_COOLING 100 >/dev/null
poll_num 40 "ir $IR_TEMP" -le $((TEMP_BASE + 15)) >/dev/null || true

# ── Chain C: tripping a breaker collapses its feeder ────────────────────────────

echo "[control] Chain C: breaker open collapses feeder voltage"

wait_steady
VA_BASE=$(ir $IR_V_A)
echo "[control] baseline feeder-A voltage ${VA_BASE}V; tripping uupl-breaker-a (coil[1]=1)"
mb "$BRKA_IP" write 1 1 1 >/dev/null

# PLC mirrors the breaker's open state into its own coil via the sync loop.
if poll_num 20 "co $CO_BREAKER_A" -eq 0 >/dev/null; then
    ok "PLC mirrored the open breaker into COIL[5] (actuator -> PLC sync loop)"
else
    fail "PLC did not mirror the open breaker within 20s"
fi
VA_OPEN=$(poll_num 20 "ir $IR_V_A" -lt 20)
if [ "$?" -eq 0 ]; then
    ok "feeder-A voltage collapsed ${VA_BASE}V -> ${VA_OPEN}V after breaker trip"
else
    fail "feeder-A voltage did not collapse (baseline ${VA_BASE}V, last ${VA_OPEN}V)"
fi
if [ "$(co $CO_ALM_VOLT)" = "1" ]; then
    ok "undervoltage alarm raised on feeder loss (COIL[4])"
else
    fail "undervoltage alarm did not raise after feeder loss"
fi

echo "[control] reclosing uupl-breaker-a (coil[2]=1)"
mb "$BRKA_IP" write 1 2 1 >/dev/null
if poll_num 20 "co $CO_BREAKER_A" -eq 1 >/dev/null; then
    ok "breaker reclosed and PLC mirror recovered (COIL[5]=1)"
else
    fail "breaker did not reclose within 20s"
fi
poll_num 30 "ir $IR_V_A" -gt 100 >/dev/null || true

# ── Chain D: governor setpoint drives an overspeed trip ─────────────────────────

echo "[control] Chain D: setpoint over the trip line forces an overspeed trip"

wait_steady
RPM_BASE=$(ir $IR_RPM)
echo "[control] baseline ${RPM_BASE} RPM; pushing governor setpoint to 3600 (above ${RPM_TRIP} trip)"
mb "$PLC_IP" write 3 $HR_SETPOINT 3600 >/dev/null

# The shaft accelerates past the trip line and the PLC latches e-stop.
if poll_num 60 "co $CO_ESTOP" -eq 1 >/dev/null; then
    ok "overspeed past ${RPM_TRIP} RPM latched the e-stop (COIL[0]=1)"
else
    fail "e-stop did not latch within 60s of raising the setpoint"
fi
# E-stop cuts fuel, so the shaft spins down.
RPM_TRIPPED=$(poll_num 40 "ir $IR_RPM" -lt 1800)
if [ "$?" -eq 0 ]; then
    ok "e-stop cut fuel and the shaft spun down ${RPM_BASE} -> ${RPM_TRIPPED} RPM"
else
    fail "shaft did not spin down after e-stop (last ${RPM_TRIPPED} RPM)"
fi

echo "[control] restoring setpoint (3000) and clearing e-stop"
mb "$PLC_IP" write 3 $HR_SETPOINT 3000 >/dev/null
mb "$PLC_IP" write 1 $CO_ESTOP 0 >/dev/null
if poll_num 90 "ir $IR_RPM" -gt 2500 >/dev/null; then
    echo "[control] plant recovered to running speed"
else
    echo "[control] note: plant had not fully recovered to 2500 RPM when the test ended"
fi

# ── Chain E: direct fuel-valve actuator write ────────────────────────────────

echo "[control] Chain E: direct fuel-valve actuator write (no auth enforcement)"

wait_steady

FUELV_BEFORE=$(mb "$FUELV_IP" read 3 0)
echo "[control] fuel valve HR[0] = ${FUELV_BEFORE}%; writing 0 then reading back in one connection"

# Write and read back in the same Python connection. The PLC overwrites the
# actuator every ~1 s; a same-connection readback precedes the next PLC push.
FUELV_AFTER=$(docker exec -i "$ENGWS" /venv/bin/python3 - "$FUELV_IP" <<'PY'
import sys
from pymodbus.client import ModbusTcpClient
c = ModbusTcpClient(sys.argv[1], port=502, timeout=3)
if not c.connect(): print("ERR"); sys.exit(1)
c.write_register(0, 0, slave=1)
r = c.read_holding_registers(0, 1, slave=1)
c.close()
print(r.registers[0] if not r.isError() else "ERR")
PY
)

if [ "$FUELV_AFTER" = "0" ]; then
    ok "fuel valve actuator accepted unauthenticated write from eng-ws (HR[0] = 0)"
else
    fail "fuel valve write not reflected in same-connection readback (got $FUELV_AFTER)"
fi

# The PLC governor re-asserts its fuel command within ~1 s; plant does not stall.
sleep 3
RPM_E=$(ir $IR_RPM)
if [ "${RPM_E:-0}" -gt 1500 ]; then
    ok "governor re-asserted fuel valve; plant still running after direct actuator write (${RPM_E} RPM)"
else
    fail "plant stalled after direct actuator write (${RPM_E} RPM)"
fi

# ── Chain F: overspeed -> relay-a trips, MQTT event, auto-reclose ────────────

echo "[control] Chain F: overspeed triggers relay-a trip, MQTT event, and auto-reclose"

wait_steady
echo "[control] subscribing to uupl/relay/a/trip, then pushing governor setpoint to 3600"

RELAY_TRIP_JSON=$(docker exec -i "$ENGWS" /venv/bin/python3 - "$MQTT_IP" "$PLC_IP" <<'PY'
import sys, time
import paho.mqtt.client as mqtt
from pymodbus.client import ModbusTcpClient

mqtt_ip, plc_ip = sys.argv[1], sys.argv[2]

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
time.sleep(0.5)

mb = ModbusTcpClient(plc_ip, port=502, timeout=3)
mb.connect()
mb.write_register(0, 3600, slave=1)
mb.close()

for _ in range(600):
    if "msg" in got: break
    time.sleep(0.1)
mc.loop_stop()
print(got.get("msg", ""))
PY
)

if echo "$RELAY_TRIP_JSON" | grep -qE '"relay_id"'; then
    ok "relay-a published trip event to uupl/relay/a/trip on overspeed"
else
    fail "no relay trip MQTT event received within 60 s"
fi
if echo "$RELAY_TRIP_JSON" | grep -qE '"cause": "(overspeed|undervoltage|overcurrent)"'; then
    ok "relay trip cause is a genuine fault condition (relay detected independently)"
else
    fail "relay trip cause not a genuine fault: $RELAY_TRIP_JSON"
fi

RELAY_COIL() { mb "$RELAYA_IP" read 1 0; }
RECLOSED=$(poll_num 25 RELAY_COIL -eq 0)
if [ "${RECLOSED:-1}" = "0" ]; then
    ok "relay-a auto-reclosed after overspeed trip (COIL[0] = 0 within 25 s)"
else
    fail "relay-a did not auto-reclose within 25 s (COIL[0] = ${RECLOSED})"
fi

echo "[control] restoring setpoint (3000) and clearing e-stop after chain F"
mb "$PLC_IP" write 3 $HR_SETPOINT 3000 >/dev/null
mb "$PLC_IP" write 1 $CO_ESTOP 0 >/dev/null
if poll_num 90 "ir $IR_RPM" -gt 2500 >/dev/null; then
    echo "[control] plant recovered to running speed"
else
    echo "[control] note: plant had not fully recovered to 2500 RPM when the test ended"
fi

summary