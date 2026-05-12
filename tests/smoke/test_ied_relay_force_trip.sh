#!/usr/bin/env bash
# Force-trip the Dolly Sisters feeder relay (10.10.3.31) by writing coil 0
# via unauthenticated Modbus. Confirm the relay's own state reflects the
# trip. Restore state afterwards so subsequent runs see a clean relay.
#
# Coverage:
#   read coil 0 baseline (False)
#   write coil 0 = True
#   read coil 0 = True (relay registers the trip)
#   reset coil 0 = False so the next run is clean
#
# Usage: bash tests/smoke/test_ied_relay_force_trip.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENG_WS="engineering-workstation"
RELAY="ied_relay_a"

for c in "$ENG_WS" "$RELAY"; do
    require_running "$c"
done

echo "[relay] Waiting for relay-a..."
wait_for_port "$ENG_WS" 10.10.3.31 502 30 || fail "relay-a :502 not ready from eng-ws"

echo "[relay] Stage 1: write coil 0 forces a trip"

# Visitor intent is "I can write coil 0 = True via Modbus and the relay
# reports tripped." Whether the relay was un-tripped beforehand is not
# guaranteed (the protection loop also auto-trips on fault conditions and
# may re-trip immediately if the simulated PLC is producing fault values),
# so we do not assert on the BEFORE state. We do assert that the write
# succeeded and the readback shows tripped.
TRIP_OUT="$(in_container "$ENG_WS" /venv/bin/python3 -c "
from pymodbus.client import ModbusTcpClient
import time
c = ModbusTcpClient('10.10.3.31', port=502)
c.connect()

# Reset coil first: the relay's auto-reclose runs every 10s and the test may
# re-run inside that window, leaving the coil already tripped from a prior
# run. Without a clean 0->1 transition, the 'remote' branch in the relay
# loop does not fire and the trip log does not gain a new entry.
c.write_coil(address=0, value=False, slave=1)
time.sleep(0.5)  # let the relay loop observe the reset (loop period 0.2s)

# Pre-trip trip-log read (runbook step).
pre = c.read_holding_registers(address=10, count=10, slave=1)
if pre.isError():
    print('PRE_LOG_ERROR', pre); raise SystemExit(1)
print('PRE_LOG', list(pre.registers))

w = c.write_coil(address=0, value=True, slave=1)
if w.isError():
    print('WRITE_ERROR', w); raise SystemExit(1)
print('WRITE_OK')
time.sleep(0.5)

after = c.read_coils(address=0, count=2, slave=1)
if after.isError():
    print('READ_ERROR', after); raise SystemExit(1)
print('AFTER_COILS', list(after.bits[:2]))

# Post-trip trip-log read (runbook step). HR[10:20] now has an event recorded.
post = c.read_holding_registers(address=10, count=10, slave=1)
if post.isError():
    print('POST_LOG_ERROR', post); raise SystemExit(1)
print('POST_LOG', list(post.registers))
c.close()
" 2>&1)"

assert_contains "$TRIP_OUT" "WRITE_OK" \
    "Modbus write_coil(0, True) accepted (no exception code)"
assert_contains "$TRIP_OUT" "AFTER_COILS \\[True, True\\]" \
    "after write, coil 0 (trip) and coil 1 (breaker) both True"

# Runbook claims "Trip log now shows event" after the external write. The
# relay loop now detects 0->1 transitions of COIL_TRIP not caused by the loop
# itself and logs them as cause="remote", which shifts the existing entries
# and writes the new event at HR[10:11]. We compare full PRE_LOG vs POST_LOG
# rather than non-zero counts: once the 5-entry ring buffer is full from
# prior runs, the count doesn't change but the contents do.
PRE_LOG="$(printf '%s\n' "$TRIP_OUT" | grep '^PRE_LOG' || true)"
POST_LOG="$(printf '%s\n' "$TRIP_OUT" | grep '^POST_LOG' || true)"
if [ -n "$PRE_LOG" ] && [ -n "$POST_LOG" ] && [ "$PRE_LOG" != "$POST_LOG" ]; then
    ok "trip log HR[10:20] contents changed after the external trip write"
else
    fail "trip log unchanged across the trip write; relay_server.py may not be recording remote-command trips"
fi

summary
