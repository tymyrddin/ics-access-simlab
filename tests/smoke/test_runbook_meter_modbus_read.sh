#!/usr/bin/env bash
# Smoke test: books/meter-modbus-read.md
#
# Read-only Modbus probe of the revenue meter (10.10.3.33). Five input
# registers expose live turbine telemetry derived from the PLC simulation.
# No write, no side effects. Reachable from eng-ws's control NIC.
#
# Coverage:
#   read input registers 0..4 returns 5 values, all non-zero (PLC live)
#
# Usage: bash tests/smoke/test_runbook_meter_modbus_read.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENG_WS="engineering-workstation"
METER="ied_meter_main"
PLC="turbine_plc"

for c in "$ENG_WS" "$METER" "$PLC"; do
    require_running "$c"
done

echo "[meter] Waiting for meter and turbine PLC..."
wait_for_port "$ENG_WS" 10.10.3.33 502 30 || fail "meter :502 not ready from eng-ws"
wait_for_port "$ENG_WS" 10.10.3.21 502 30 || fail "turbine PLC :502 not ready from eng-ws"

echo "[meter] Stage 1: unauthenticated Modbus read of input registers 0..4"

# Poll until the PLC simulation has spun up and the meter is reflecting live
# values. Just-after-up the PLC's input registers are all zero for a few
# seconds; a real visitor would also see this and re-read.
READ_OUT=""
NONZERO_COUNT=0
for _ in $(seq 1 15); do
    READ_OUT="$(in_container "$ENG_WS" /venv/bin/python3 -c "
from pymodbus.client import ModbusTcpClient
c = ModbusTcpClient('10.10.3.33', port=502)
c.connect()
r = c.read_input_registers(address=0, count=5, slave=1)
c.close()
if r.isError():
    print('ERROR', r); raise SystemExit(1)
print('OK', list(r.registers))
" 2>&1)"
    NONZERO_COUNT="$(printf '%s' "$READ_OUT" | grep -oE '[0-9]+' | grep -cv '^0$')"
    [ "$NONZERO_COUNT" -ge 3 ] && break
    sleep 2
done

assert_contains "$READ_OUT" "^OK \\[" "meter read_input_registers(0,5) succeeds"
if [ "$NONZERO_COUNT" -ge 3 ]; then
    ok "meter values look live ($NONZERO_COUNT/5 non-zero)"
else
    fail "meter values mostly zero ($NONZERO_COUNT/5 non-zero), PLC simulation not warming up"
fi

summary
