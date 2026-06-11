#!/usr/bin/env bash
# uupl-hmi (FUXA) smoke test.
#
# Coverage:
#   Connectivity: :1881
#   Unauthenticated GET /api/project returns project name, FuxaServer type,
#     Modbus device (hex-turbine-plc, 10.10.3.21), and key tags (turbine_rpm,
#     governor_setpoint_rpm, emergency_stop) — all exposed without auth
#   Unauthenticated POST /api/project is accepted (CVE-2023-32547 / CVE-2023-32546)
#
# The write test posts the project back unchanged, so it is idempotent.
#
# Usage: bash tests/smoke/test_uupl_hmi.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENGWS="uupl-eng-ws"
HMI="uupl-hmi"
HMI_IP="10.10.3.10"

require_running "$ENGWS"
require_running "$HMI"

# ── Connectivity ──────────────────────────────────────────────────────────────

echo "[uupl-hmi] Connectivity"

if probe_tcp control "$HMI_IP" 1881; then
    ok "FUXA port 1881 reachable from control zone"
else
    fail "FUXA port 1881 not reachable"
fi

# ── Unauthenticated project read ──────────────────────────────────────────────

echo "[uupl-hmi] Unauthenticated project access"

GET_OUT=$(in_container "$ENGWS" curl -s --max-time 10 "http://$HMI_IP:1881/api/project")

assert_contains "$GET_OUT" "UUPL Control HMI"      "GET /api/project returns project name (no auth required)"
assert_contains "$GET_OUT" "FuxaServer"             "GET /api/project contains FuxaServer type"
assert_contains "$GET_OUT" "hex-turbine-plc"        "GET /api/project exposes Modbus device name"
assert_contains "$GET_OUT" "10\.10\.3\.21"          "GET /api/project exposes PLC IP address"
assert_contains "$GET_OUT" "turbine_rpm"            "GET /api/project exposes turbine_rpm tag"
assert_contains "$GET_OUT" "governor_setpoint_rpm"  "GET /api/project exposes writable governor setpoint tag"
assert_contains "$GET_OUT" "emergency_stop"         "GET /api/project exposes emergency_stop coil tag"

# ── Unauthenticated project write ─────────────────────────────────────────────

echo "[uupl-hmi] Unauthenticated project write"

POST_CODE=$(in_container "$ENGWS" curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
    -X POST "http://$HMI_IP:1881/api/project" \
    -H "Content-Type: application/json" \
    -d "$GET_OUT")

[ "$POST_CODE" = "200" ] \
    && ok   "POST /api/project returns 200 without authentication" \
    || fail "POST /api/project: expected 200, got $POST_CODE"

GET2_OUT=$(in_container "$ENGWS" curl -s --max-time 10 "http://$HMI_IP:1881/api/project")
assert_contains "$GET2_OUT" "FuxaServer" "project still readable after unauthenticated POST"

summary
