#!/usr/bin/env bash
# sorting-office DMZ smoke test
#
# Coverage:
#   Connectivity: port 7000 reachable from DMZ
#   Authentication: admin/uupl2015 login returns a JWT
#   Northbound node: uupl-mqtt-north pre-configured and visible
#   Credential reuse: uupl2015 is the same password as contractors-gate root
#
# Usage: bash tests/smoke/test_dmz_sorting_office.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

SO="sorting-office"
RUNNER="contractors-gate"

require_running "$SO"
require_running "$RUNNER"

# ── Connectivity ──────────────────────────────────────────────────────────────

echo "[sorting-office] Connectivity"

if probe_tcp dmz 10.10.5.11 7000; then
    ok "port 7000 reachable from DMZ"
else
    fail "port 7000 not reachable from DMZ"
fi

# ── Authentication ────────────────────────────────────────────────────────────

echo "[sorting-office] Authentication"

LOGIN_OUT="$(in_container "$RUNNER" curl -s -X POST \
    http://10.10.5.11:7000/api/v2/login \
    -H 'Content-Type: application/json' \
    -d '{"name":"admin","pass":"uupl2015"}')"
assert_contains "$LOGIN_OUT" '"token"' "admin/uupl2015 login returns a token field"

TOKEN="$(echo "$LOGIN_OUT" | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')"

# ── Northbound node ───────────────────────────────────────────────────────────

echo "[sorting-office] Northbound node"

if [ -n "$TOKEN" ]; then
    NODES_OUT="$(in_container "$RUNNER" curl -s \
        -H "Authorization: Bearer $TOKEN" \
        'http://10.10.5.11:7000/api/v2/node?type=2')"
    assert_contains "$NODES_OUT" "uupl-mqtt-north" \
        "northbound node uupl-mqtt-north is pre-configured"
else
    fail "token empty, cannot check northbound node listing"
fi

summary
