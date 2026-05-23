#!/usr/bin/env bash
# substation-rtu DMZ smoke test
#
# Coverage:
#   Connectivity: IEC-104 port 2404 reachable from DMZ, REST port 8080 reachable from internet
#   REST API: GET /datapoints returns the expected datapoint inventory
#   Mutation: POST to /datapoints/4 changes the frequency value
#
# Note: state is in-memory. A container restart resets all values to their
# defaults in rtu_config.json. That is expected behaviour, not a test failure.
#
# Usage: bash tests/smoke/test_dmz_substation_rtu.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

RTU="substation-rtu"
RUNNER="contractors-gate"
ATTACKER="unseen-gate"

require_running "$RTU"
require_running "$RUNNER"
require_running "$ATTACKER"

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

summary
