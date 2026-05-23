#!/usr/bin/env bash
# distribution-scada Windows Server 2016 facade smoke test
#
# Coverage:
#   Identity: whoami, hostname, ipconfig, netstat -ano
#   Configuration: scada.ini (all four credential sets), alarm_recipients.txt
#   Scripts: send_alarm.bat (SMTP password), poll_historian.ps1 (ingest creds)
#   Alarm log: alarm_log_2026.txt (trip events with thresholds)
#   PSReadLine: history shows historian API queries
#   Certificates: dir certs\, cat client.key (world-readable PEM)
#   Desktop: README.txt (quick reference card)
#   Web interface: version disclosure header, admin:admin auth, /config dump,
#                  /historian-pass proxy endpoint
#   SSH auth: scada_admin/W1nd0ws@2016 via wizzards-retreat jump
#   Credential chain: hist_read/history2017 (from scada.ini) against historian /report
#
# Usage: bash tests/smoke/test_distribution_scada_facade.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

SCADA="distribution-scada"
JUMP="wizzards-retreat"
ATTACKER="unseen-gate"
HIST="uupl-historian"

require_running "$SCADA"
require_running "$JUMP"
require_running "$ATTACKER"
require_running "$HIST"

ps1() { in_container "$SCADA" /usr/local/bin/winserver2016_shell.sh -c "$1"; }

SCADA_IP=$(container_ip "$SCADA" operational)
HIST_IP=$(container_ip "$HIST" operational)

echo "[distribution-scada] Waiting for SSH on $SCADA_IP..."
if ! wait_for_port "$JUMP" "$SCADA_IP" 22 30; then
    fail "distribution-scada :22 not ready within 30s"
    summary; exit 1
fi

# ── Identity ──────────────────────────────────────────────────────────────────

echo "[distribution-scada] Identity"

WHOAMI_OUT="$(ps1 "whoami")"
assert_contains "$WHOAMI_OUT" "scada_admin" "whoami contains scada_admin"

HOST_OUT="$(ps1 "hostname")"
assert_contains "$HOST_OUT" "SCADA-SRV01" "hostname returns SCADA-SRV01"

IPCFG_OUT="$(ps1 "ipconfig")"
assert_contains "$IPCFG_OUT" "${SCADA_IP//./\\.}" "ipconfig shows operational IP ($SCADA_IP)"

NETSTAT_OUT="$(ps1 "netstat -ano")"
assert_contains "$NETSTAT_OUT" "8080"          "netstat shows port 8080 (SCADA web)"
assert_contains "$NETSTAT_OUT" "5020"          "netstat shows 127.0.0.1:5020 (stunnel Modbus relay)"

DIR_HOME="$(ps1 "dir")"
assert_contains "$DIR_HOME" "[0-9][0-9]/[0-9][0-9]/[0-9][0-9][0-9][0-9]" \
    "dir shows real file timestamps (not hardcoded)"

# ── Configuration file ────────────────────────────────────────────────────────

echo "[distribution-scada] Configuration file"

INI_OUT="$(ps1 'cat C:\SCADA\Config\scada.ini')"
assert_contains "$INI_OUT" "hist_read"     "scada.ini contains hist_read"
assert_contains "$INI_OUT" "history2017"   "scada.ini contains history2017"
assert_contains "$INI_OUT" "admin"         "scada.ini contains web admin account"
assert_contains "$INI_OUT" "plantmail123"  "scada.ini contains SMTP relay password"
assert_contains "$INI_OUT" "W1nd0ws@2016"  "scada.ini contains SSH admin password"

RECIP_OUT="$(ps1 'cat C:\SCADA\Config\alarm_recipients.txt')"
assert_contains "$RECIP_OUT" "ops-duty|uupl\.am|@" "alarm_recipients.txt contains notification addresses"

# ── Scripts ───────────────────────────────────────────────────────────────────

echo "[distribution-scada] Scripts"

BAT_OUT="$(ps1 'cat C:\SCADA\Scripts\send_alarm.bat')"
assert_contains "$BAT_OUT" "plantmail123" "send_alarm.bat contains SMTP password in plaintext"

PS_OUT="$(ps1 'cat C:\SCADA\Scripts\poll_historian.ps1')"
assert_contains "$PS_OUT" "hist_read"   "poll_historian.ps1 contains ingest username"
assert_contains "$PS_OUT" "history2017" "poll_historian.ps1 contains ingest password"

# ── Alarm log ─────────────────────────────────────────────────────────────────

echo "[distribution-scada] Alarm log"

LOG_OUT="$(ps1 'cat C:\SCADA\Logs\alarm_log_2026.txt')"
assert_contains "$LOG_OUT" "timestamp|severity|asset|ALARM|trip|overspeed" \
    "alarm_log_2026.txt contains trip or threshold events"

# ── PSReadLine history ─────────────────────────────────────────────────────────

echo "[distribution-scada] PSReadLine history"

HIST_TXT="$(ps1 'cat AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt')"
assert_contains "$HIST_TXT" "10\.10\.2\.10|historian|8080" \
    "PSReadLine history shows historian API queries"

# ── Certificates ──────────────────────────────────────────────────────────────

echo "[distribution-scada] Certificates"

CERTS_DIR="$(ps1 'dir C:\SCADA\Config\certs\')"
assert_contains "$CERTS_DIR" "client\.key"  "certs dir contains client.key"
assert_contains "$CERTS_DIR" "client\.crt"  "certs dir contains client.crt"
assert_contains "$CERTS_DIR" "ca\.crt"      "certs dir contains ca.crt"

KEY_OUT="$(ps1 'cat C:\SCADA\Config\certs\client.key')"
assert_contains "$KEY_OUT" "BEGIN.*KEY|PRIVATE" "client.key is a readable PEM (world-readable)"

# ── Desktop quick reference ───────────────────────────────────────────────────

echo "[distribution-scada] Desktop README"

README_OUT="$(ps1 'cat Desktop\README.txt')"
assert_contains "$README_OUT" "8080|http|admin|config|historian" \
    "Desktop README.txt is the operator credential quick reference"

# ── Web interface ─────────────────────────────────────────────────────────────

echo "[distribution-scada] Web interface"

HDR_OUT="$(in_container "$JUMP" curl -sv --max-time 10 \
    -u admin:admin "http://${SCADA_IP}:8080/" 2>&1)"
assert_contains "$HDR_OUT" "UU-SCADA|Flask|Python" \
    "X-Powered-By header discloses UU-SCADA/Flask/Python version"
assert_contains "$HDR_OUT" "200" \
    "admin:admin authenticates to SCADA web interface"

UNAUTH_OUT="$(in_container "$JUMP" curl -sv --max-time 10 \
    "http://${SCADA_IP}:8080/" 2>&1)"
assert_contains "$UNAUTH_OUT" "401|Unauthorized" \
    "unauthenticated request returns 401"
assert_contains "$UNAUTH_OUT" "UU-SCADA|Flask|Python" \
    "version header present on 401 response (pre-auth disclosure)"

CFG_OUT="$(in_container "$JUMP" curl -s --max-time 10 \
    -u admin:admin "http://${SCADA_IP}:8080/config")"
assert_contains "$CFG_OUT" "hist_read|history2017" \
    "/config endpoint returns historian credentials"
assert_contains "$CFG_OUT" "plantmail123" \
    "/config endpoint returns SMTP relay password"

HISTPASS_OUT="$(in_container "$JUMP" curl -s --max-time 10 \
    -u admin:admin "http://${SCADA_IP}:8080/historian-pass")"
assert_contains "$HISTPASS_OUT" "200|timestamp|turbine|rpm|ok" \
    "/historian-pass endpoint proxies historian report"

# ── SSH auth via jump ─────────────────────────────────────────────────────────

echo "[distribution-scada] SSH authentication"

SSH_OUT="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    scada_admin "$SCADA_IP" 'W1nd0ws@2016')"
assert_contains "$SSH_OUT" "SSH_OK" \
    "scada_admin/W1nd0ws@2016 authenticates via wizzards-retreat jump"

SSH_CMD="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    scada_admin "$SCADA_IP" 'W1nd0ws@2016' \
    "hostname")"
assert_contains "$SSH_CMD" "SCADA-SRV01" \
    "SSH exec via jump: hostname returns SCADA-SRV01 through facade"

# ── Credential chain ──────────────────────────────────────────────────────────

echo "[distribution-scada] Credential chain"

HIST_MONTH="$(date +%Y-%m)"
REPORT_OUT="$(in_container "$JUMP" curl -s --max-time 10 \
    -u hist_read:history2017 \
    "http://${HIST_IP}:8080/report?asset=turbine_rpm&from=${HIST_MONTH}-01&to=${HIST_MONTH}-28")"
assert_contains "$REPORT_OUT" "timestamp,value,unit" \
    "hist_read/history2017 (from scada.ini) retrieves historian /report"

summary
