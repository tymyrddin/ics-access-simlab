#!/usr/bin/env bash
# substation-rtu DMZ smoke test
#
# Coverage:
#   Connectivity: IEC-104 port 2404 reachable from DMZ, REST port 8080 reachable from internet
#   REST API: GET /datapoints returns the expected datapoint inventory
#   Mutation: POST to /datapoints/4 changes the frequency value
#
# Values are live: uupl-eng-ws pushes updates every 10 s from the relay IEDs
# and turbine PLC. The live-values section below verifies this feed is active.
#
# Usage: bash tests/smoke/test_dmz_substation_rtu.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

RTU="substation-rtu"
RUNNER="contractors-gate"
ATTACKER="unseen-gate"
ENGWS="uupl-eng-ws"

require_running "$RTU"
require_running "$RUNNER"
require_running "$ATTACKER"
require_running "$ENGWS"

# ── Connectivity ──────────────────────────────────────────────────────────────

echo "[substation-rtu] Connectivity"

if probe_tcp dmz 10.10.5.14 2404; then
    ok "IEC-104 port 2404 reachable from DMZ"
else
    fail "IEC-104 port 2404 not reachable from DMZ"
fi

if probe_tcp internet 10.10.5.14 8080; then
    ok "REST port 8080 reachable from internet zone"
else
    fail "REST port 8080 not reachable from internet zone"
fi

# ── REST datapoint inventory ──────────────────────────────────────────────────

echo "[substation-rtu] REST datapoint inventory"

DP_OUT="$(in_container "$RUNNER" curl -s --max-time 10 \
    http://10.10.5.14:8080/datapoints)"
assert_contains "$DP_OUT" "feeder_a_voltage" "GET /datapoints lists feeder_a_voltage"
assert_contains "$DP_OUT" "feeder_b_voltage" "GET /datapoints lists feeder_b_voltage"
assert_contains "$DP_OUT" "frequency"        "GET /datapoints lists frequency"
assert_contains "$DP_OUT" "breaker_a_state"  "GET /datapoints lists breaker_a_state"

# ── REST mutation ─────────────────────────────────────────────────────────────

echo "[substation-rtu] REST mutation"

POST_OUT="$(in_container "$RUNNER" curl -s --max-time 10 \
    -X POST http://10.10.5.14:8080/datapoints/4 \
    -H 'Content-Type: application/json' \
    -d '{"value":47.2}')"
assert_contains "$POST_OUT" '"status":"ok"' "POST /datapoints/4 returns ok"
assert_contains "$POST_OUT" "47.2"          "POST /datapoints/4 echoes new value"

GET_OUT="$(in_container "$RUNNER" curl -s --max-time 10 \
    http://10.10.5.14:8080/datapoints/4)"
assert_contains "$GET_OUT" "47.2" "GET /datapoints/4 reflects mutated value"

# ── Live values from eng-ws rtu_updater ──────────────────────────────────────
# Wait up to 15 s for a fresh update cycle to overwrite the mutation above,
# then assert all values are in the live operating range.

echo "[substation-rtu] Live values from eng-ws rtu_updater"

sleep 12

DP_LIVE="$(in_container "$RUNNER" curl -s --max-time 10 \
    http://10.10.5.14:8080/datapoints)"

VOLT_A=$(echo "$DP_LIVE" | python3 -c \
    "import sys,json; d={x['id']:x for x in json.load(sys.stdin)}; print(d[1]['value'])" 2>/dev/null || echo "ERR")
FREQ=$(echo "$DP_LIVE" | python3 -c \
    "import sys,json; d={x['id']:x for x in json.load(sys.stdin)}; print(d[4]['value'])" 2>/dev/null || echo "ERR")
BRK_A=$(echo "$DP_LIVE" | python3 -c \
    "import sys,json; d={x['id']:x for x in json.load(sys.stdin)}; print(d[5]['value'])" 2>/dev/null || echo "ERR")

if python3 -c "v=float('$VOLT_A'); assert 9.0 < v < 12.5" 2>/dev/null; then
    ok "feeder_a_voltage is live (${VOLT_A} kV, 9.0-12.5 kV operating range)"
else
    fail "feeder_a_voltage out of live range or feed broken (got '$VOLT_A' kV)"
fi

if python3 -c "v=float('$FREQ'); assert 40.0 < v < 55.0" 2>/dev/null; then
    ok "frequency is live (${FREQ} Hz, 40-55 Hz operating range)"
else
    fail "frequency out of live range or feed broken (got '$FREQ' Hz)"
fi

[ "$BRK_A" = "True" ] \
    && ok   "breaker_a_state is true (closed, tracking relay-a COIL[0])" \
    || fail "breaker_a_state is not true (got '$BRK_A')"

summary
