#!/usr/bin/env bash
# bursar-desk Windows 10 facade smoke test
#
# Coverage:
#   Identity: whoami (plain, /groups), hostname, systeminfo, net localgroup
#   Network: ipconfig /all (dual-homed), arp -a, route print (operational route),
#            netstat, ping loopback, ping historian directly
#   File hunting: dir /s *.conf, *.ps1, *.csv; dir named paths
#   Credential discovery: type ops-access.conf, type script, type history,
#                         findstr /i, cmdkey /list
#   Scheduled tasks: schtasks /query
#   Process listing: tasklist
#   Unknown command: returns recognizable error
#   Live service: curl historian /assets using loot credentials
#   SSH auth: bursardesk/Octavo1 via wizzards-retreat jump
#   Credential chain: historian:Historian2015 (from ops-access.conf) against
#                     historian ingest; admin:admin against distribution-scada
#
# Usage: bash tests/smoke/test_bursar_desk_facade.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

BURSAR="bursar-desk"
ATTACKER="unseen-gate"
JUMP="wizzards-retreat"

require_running "$BURSAR"
require_running "$ATTACKER"
require_running "$JUMP"
require_running "uupl-historian"
require_running "distribution-scada"

# Run a PowerShell facade command through -c mode (no SSH, no network).
ps1() { in_container "$BURSAR" /usr/local/bin/win10shell.sh -c "$1"; }

# Discover real IPs from running containers.
BURSAR_ENT_IP=$(docker exec "$BURSAR" hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.1\.' | head -1)
BURSAR_OPS_IP=$(docker exec "$BURSAR" hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.2\.' | head -1)
HIST_IP=$(docker exec uupl-historian hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.2\.' | head -1)
SCADA_IP=$(docker exec distribution-scada hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.2\.' | head -1)

echo "[bursar-desk] Waiting for SSH on $BURSAR_ENT_IP..."
if ! wait_for_port "$JUMP" "$BURSAR_ENT_IP" 22 30; then
    fail "bursar-desk :22 not ready within 30s"
    summary; exit 1
fi

# ── Identity ──────────────────────────────────────────────────────────────────

echo "[bursar-desk] Identity"

WHOAMI_OUT="$(ps1 "whoami")"
assert_contains "$WHOAMI_OUT" "bursardesk" "whoami contains bursardesk"

HOST_OUT="$(ps1 "hostname")"
assert_contains "$HOST_OUT" "BURSAR-DESK" "hostname returns BURSAR-DESK"

SYSINFO_OUT="$(ps1 "systeminfo")"
assert_contains "$SYSINFO_OUT" "UUPL" "systeminfo shows UUPL domain"
assert_contains "$SYSINFO_OUT" "Windows 10" "systeminfo shows Windows 10"

GROUPS_OUT="$(ps1 "whoami /groups")"
assert_contains "$GROUPS_OUT" "UUPL" "whoami /groups shows UUPL domain membership"

LOCALGROUP_OUT="$(ps1 "net localgroup Administrators")"
assert_contains "$LOCALGROUP_OUT" "bursardesk" "net localgroup Administrators lists bursardesk"

# ── Network: dual-homed discovery ─────────────────────────────────────────────

echo "[bursar-desk] Network"

IPALL_OUT="$(ps1 "ipconfig /all")"
assert_contains "$IPALL_OUT" "${BURSAR_ENT_IP//./\\.}" \
    "ipconfig /all shows enterprise IP ($BURSAR_ENT_IP)"
assert_contains "$IPALL_OUT" "${BURSAR_OPS_IP//./\\.}" \
    "ipconfig /all shows operational IP ($BURSAR_OPS_IP) — dual-homed"
assert_contains "$IPALL_OUT" "Ethernet 1" \
    "ipconfig /all lists second adapter"

ARP_OUT="$(ps1 "arp -a")"
assert_contains "$ARP_OUT" "10\.10\." "arp -a shows ARP entries"

ROUTE_OUT="$(ps1 "route print")"
assert_contains "$ROUTE_OUT" "10\.10\.2\.0" \
    "route print shows operational subnet 10.10.2.0 (key dual-homed discovery)"

NETSTAT_OUT="$(ps1 "netstat")"
assert_contains "$NETSTAT_OUT" "Active Connections" "netstat shows Active Connections header"

PING_LO="$(ps1 "ping 127.0.0.1")"
assert_contains "$PING_LO" "Reply from 127\.0\.0\.1" "ping loopback gets replies"

PING_HIST="$(ps1 "ping $HIST_IP")"
assert_contains "$PING_HIST" "Reply from ${HIST_IP//./\\.}" \
    "ping historian ($HIST_IP) gets replies via operational interface"

# ── File hunting ──────────────────────────────────────────────────────────────

echo "[bursar-desk] File hunting"

CONF_OUT="$(ps1 "dir /s *.conf")"
assert_contains "$CONF_OUT" "ops-access\.conf" "dir /s *.conf finds ops-access.conf"

PS1_OUT="$(ps1 "dir /s *.ps1")"
assert_contains "$PS1_OUT" "pull_monthly_report" "dir /s *.ps1 finds pull_monthly_report.ps1"

CSV_OUT="$(ps1 "dir /s *.csv")"
assert_contains "$CSV_OUT" "turbine_2024" "dir /s *.csv finds turbine CSV reports"

DOCS_OUT="$(ps1 'dir Documents\')"
assert_contains "$DOCS_OUT" "notes\.txt" "dir Documents\ lists notes.txt"

APPDATA_OUT="$(ps1 'dir AppData\Roaming\UUPLOps\')"
assert_contains "$APPDATA_OUT" "ops-access\.conf" "dir AppData\Roaming\UUPLOps\ shows ops-access.conf"

REPORTS_OUT="$(ps1 'dir reports\')"
assert_contains "$REPORTS_OUT" "turbine_2024" "dir reports\ shows CSV report files"

# ── Credential discovery ──────────────────────────────────────────────────────

echo "[bursar-desk] Credential discovery"

CONF_TYPE="$(ps1 'type AppData\Roaming\UUPLOps\ops-access.conf')"
assert_contains "$CONF_TYPE" "Historian2015" \
    "type ops-access.conf reveals Historian2015 credential"
assert_contains "$CONF_TYPE" "scada\.host" \
    "type ops-access.conf reveals SCADA access"

SCRIPT_TYPE="$(ps1 'type Desktop\pull_monthly_report.ps1')"
assert_contains "$SCRIPT_TYPE" "Historian2015" \
    "type pull_monthly_report.ps1 shows hard-coded historian password"
assert_contains "$SCRIPT_TYPE" "10\.10\.2\.10" \
    "type pull_monthly_report.ps1 shows historian IP"

HIST_TYPE="$(ps1 'type AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt')"
assert_contains "$HIST_TYPE" "10\.10\.2\.10" \
    "PSReadLine history shows commands targeting historian"
assert_contains "$HIST_TYPE" "10\.10\.2\.30" \
    "PSReadLine history shows SSH to engineering workstation"

FINDSTR_OUT="$(ps1 'findstr /i pass AppData\Roaming\UUPLOps\ops-access.conf')"
assert_contains "$FINDSTR_OUT" "pass" \
    "findstr /i pass finds credential lines in ops-access.conf"

CMDKEY_OUT="$(ps1 "cmdkey /list")"
assert_contains "$CMDKEY_OUT" "uupl-historian|10\.10\.2\.10" \
    "cmdkey /list shows saved credential for historian"

NOTES_OUT="$(ps1 'type Documents\notes.txt')"
assert_contains "$NOTES_OUT" "ops-access" \
    "notes.txt points to ops-access.conf location"

# ── Scheduled tasks and processes ─────────────────────────────────────────────

echo "[bursar-desk] Scheduled tasks and processes"

SCHTASKS_OUT="$(ps1 "schtasks /query")"
assert_contains "$SCHTASKS_OUT" "MonthlyReport" "schtasks /query lists MonthlyReport task"

TASKLIST_OUT="$(ps1 "tasklist")"
assert_contains "$TASKLIST_OUT" "svchost|powershell|explorer" "tasklist shows expected processes"

# ── Drives ────────────────────────────────────────────────────────────────────

echo "[bursar-desk] Drives"

DRIVES_OUT="$(ps1 "Get-PSDrive")"
assert_contains "$DRIVES_OUT" "FileSystem" "Get-PSDrive lists FileSystem provider"

# ── Unknown command ───────────────────────────────────────────────────────────

echo "[bursar-desk] Unknown command"

UNK_OUT="$(ps1 "Get-ADUser")"
assert_contains "$UNK_OUT" "not recognized" "unrecognised command returns helpful error"

# ── Live service: credentials from loot → historian ───────────────────────────

echo "[bursar-desk] Live service verification"

# historian:Historian2015 is in ops-access.conf; verify it reaches the live historian
HIST_ASSETS="$(in_container "$BURSAR" curl -s --max-time 10 \
    -u historian:Historian2015 \
    "http://${HIST_IP}:8080/assets" 2>&1)"
assert_contains "$HIST_ASSETS" "turbine_rpm" \
    "historian:Historian2015 (from ops-access.conf) authenticates against historian /assets"

# admin:admin from ops-access.conf; verify distribution-scada returns 200
SCADA_HTTP="$(in_container "$BURSAR" curl -s --max-time 10 \
    -u admin:admin \
    -o /dev/null -w '%{http_code}' \
    "http://${SCADA_IP}:8080/" 2>&1)"
assert_contains "$SCADA_HTTP" "200" \
    "admin:admin (from ops-access.conf) authenticates against distribution-scada"

# Facade CURL: verify the facade passthrough reaches historian
FACADE_CURL="$(ps1 "curl -s -u historian:Historian2015 http://${HIST_IP}:8080/assets")"
assert_contains "$FACADE_CURL" "turbine_rpm" \
    "facade curl -u historian:Historian2015 reaches live historian /assets"

# ── SSH auth via jump ─────────────────────────────────────────────────────────

echo "[bursar-desk] SSH authentication"

SSH_OUT="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    bursardesk "$BURSAR_ENT_IP" Octavo1)"
assert_contains "$SSH_OUT" "SSH_OK" \
    "bursardesk/Octavo1 authenticates via SSH through wizzards-retreat jump"

SSH_CMD="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    bursardesk "$BURSAR_ENT_IP" Octavo1 \
    "hostname")"
assert_contains "$SSH_CMD" "BURSAR-DESK" \
    "SSH exec via jump: hostname returns BURSAR-DESK through facade"

# ── Credential chain ──────────────────────────────────────────────────────────

echo "[bursar-desk] Credential chain"

# historian:Historian2015 from ops-access.conf → /report — exactly what pull_monthly_report.ps1 does.
# This is the realistic bursar-desk chain: find credential in script, use it yourself.
HIST_MONTH="$(date +%Y-%m)"
REPORT_OUT="$(in_container "$BURSAR" curl -s --max-time 10 \
    -u historian:Historian2015 \
    "http://${HIST_IP}:8080/report?asset=turbine_rpm&from=${HIST_MONTH}-01&to=${HIST_MONTH}-28" 2>&1)"
assert_contains "$REPORT_OUT" "timestamp,value,unit" \
    "historian:Historian2015 (from ops-access.conf) retrieves /report — same path as pull_monthly_report.ps1"

summary
