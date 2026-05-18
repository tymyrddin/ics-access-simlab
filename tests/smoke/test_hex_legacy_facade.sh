#!/usr/bin/env bash
# hex-legacy-1 Windows 95 facade smoke test
#
# Coverage:
#   Basic command availability: VER, HELP, unknown command
#   Network enumeration: NET VIEW, NET VIEW \\SERVER, NET USE
#   IP/routing: WINIPCFG, IPCONFIG, ROUTE PRINT, ARP -A
#                 — all checked against the container's real IPs
#   PING: loopback, wizzards-retreat, bursar-desk (enterprise neighbours)
#   NBTSTAT: own IP, historian IP, bursar-desk IP, unknown
#             — IPs obtained from running containers, not hardcoded
#   Recursive file hunting: DIR /S with wildcards (hit and miss)
#   String search: FIND /I on C: drive and G: (SMB public share)
#   File display: TYPE
#   Output redirection: DIR > file, TYPE reads it back
#   Drive mapping: G: (pre-mapped public share)
#   CURL: historian /assets via facade CURL, validates NETWORK.TXT claim
#   SSH auth: root/hex123 via wizzards-retreat jump
#   Credential chain:
#     hist_read/history2017 (found in G:\LOGBOOK\ENGINEER.LOG) tested against historian ingest
#     bursardesk/Octavo1    (found in G:\LOGBOOK\ENGINEER.LOG) tested against bursar-desk SSH
#   SMB anonymous: public share reachable, ENGINEER.LOG retrievable
#   FTP anonymous: ENGINEER.LOG retrievable over FTP
#
# Usage: bash tests/smoke/test_hex_legacy_facade.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

LEGACY="hex-legacy-1"
ATTACKER="unseen-gate"
JUMP="wizzards-retreat"

require_running "$LEGACY"
require_running "$JUMP"

# Run a DOS command through the facade's -c mode (no SSH, no network).
dos() { in_container "$LEGACY" /usr/local/bin/win95shell.sh -c "$1"; }

# Discover real IPs from the running lab so assertions track actual topology.
LEGACY_IP=$(docker exec "$LEGACY"   hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.1\.' | head -1)
JUMP_ENT_IP=$(docker exec "$JUMP"   hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.1\.' | head -1)
BURS_ENT_IP=$(docker exec bursar-desk  hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.1\.' | head -1)
HIST_IP=$(docker exec uupl-historian   hostname -I 2>/dev/null | tr ' ' '\n' | grep '^10\.10\.2\.' | head -1)

echo "[hex-legacy] Waiting for SSH on $LEGACY_IP..."
if ! wait_for_port "$JUMP" "$LEGACY_IP" 22 30; then
    fail "hex-legacy-1 :22 not ready within 30s"
    summary; exit 1
fi

# ── Basic command availability ────────────────────────────────────────────────

echo "[hex-legacy] Basic command availability"

VER_OUT="$(dos "VER")"
assert_contains "$VER_OUT" "4\.00\.950" "VER shows Windows 95 version"

HELP_OUT="$(dos "HELP")"
assert_contains "$HELP_OUT" "DIR"      "HELP lists DIR"
assert_contains "$HELP_OUT" "FIND"     "HELP lists FIND"
assert_contains "$HELP_OUT" "WINIPCFG" "HELP lists WINIPCFG"
assert_contains "$HELP_OUT" "NBTSTAT"  "HELP lists NBTSTAT"
assert_contains "$HELP_OUT" "ROUTE"    "HELP lists ROUTE"
assert_contains "$HELP_OUT" "NET"      "HELP lists NET"

UNK_OUT="$(dos "XCOPY")"
assert_contains "$UNK_OUT" "Bad command or file name" "unrecognised command returns Bad command error"

# ── NET VIEW: workgroup and share enumeration ─────────────────────────────────

echo "[hex-legacy] NET VIEW"

VIEW_OUT="$(dos "NET VIEW")"
assert_contains "$VIEW_OUT" "HEX-LEGACY-1" "NET VIEW lists HEX-LEGACY-1"
assert_contains "$VIEW_OUT" "UUPL-SRV-01"  "NET VIEW lists UUPL-SRV-01"

VIEWSRV_OUT="$(dos 'NET VIEW \\HEX-LEGACY-1')"
assert_contains "$VIEWSRV_OUT" "public" "NET VIEW \\HEX-LEGACY-1 shows public share"

VIEWUNK_OUT="$(dos 'NET VIEW \\NOTASERVER')"
assert_contains "$VIEWUNK_OUT" "error 53|not found" "NET VIEW unknown server returns error"

# ── NET USE: drive mapping ────────────────────────────────────────────────────

echo "[hex-legacy] NET USE"

NUSE_OUT="$(dos "NET USE")"
assert_contains "$NUSE_OUT" "G:" "NET USE lists pre-mapped G: drive"
assert_contains "$NUSE_OUT" "F:" "NET USE lists pre-mapped F: drive"

MAP_OUT="$(dos 'NET USE Z: \\HEX-LEGACY-1\public')"
assert_contains "$MAP_OUT" "command completed successfully" "NET USE Z: maps public share"

# ── IP and routing commands ───────────────────────────────────────────────────

echo "[hex-legacy] IP/routing commands"

WINIPCFG_OUT="$(dos "WINIPCFG")"
assert_contains "$WINIPCFG_OUT" "${LEGACY_IP//./\\.}"   "WINIPCFG shows container's real IP ($LEGACY_IP)"
assert_contains "$WINIPCFG_OUT" "255\.255\.255\.0"       "WINIPCFG shows subnet mask"

IPCONFIG_OUT="$(dos "IPCONFIG")"
assert_contains "$IPCONFIG_OUT" "${LEGACY_IP//./\\.}" "IPCONFIG shows container's real IP"

ROUTE_OUT="$(dos "ROUTE PRINT")"
assert_contains "$ROUTE_OUT" "0\.0\.0\.0"   "ROUTE PRINT shows default route"
assert_contains "$ROUTE_OUT" "10\.10\.1\.1" "ROUTE PRINT shows enterprise gateway"

ARP_OUT="$(dos "ARP -A")"
assert_contains "$ARP_OUT" "10\.10\.1\.1" "ARP -A shows gateway entry"

# ── PING: loopback and reachable enterprise neighbours ───────────────────────

echo "[hex-legacy] PING"

PING_LO="$(dos "PING 127.0.0.1")"
assert_contains "$PING_LO" "Reply from 127\.0\.0\.1" "PING loopback gets replies"

PING_WIZ="$(dos "PING $JUMP_ENT_IP")"
assert_contains "$PING_WIZ" "Reply from ${JUMP_ENT_IP//./\\.}" \
    "PING wizzards-retreat ($JUMP_ENT_IP) gets replies"

PING_BURS="$(dos "PING $BURS_ENT_IP")"
assert_contains "$PING_BURS" "Reply from ${BURS_ENT_IP//./\\.}" \
    "PING bursar-desk ($BURS_ENT_IP) gets replies"

# ── NBTSTAT: cross-validated against real lab IPs ────────────────────────────

echo "[hex-legacy] NBTSTAT"

NBT_SELF="$(dos "NBTSTAT -A $LEGACY_IP")"
assert_contains "$NBT_SELF" "HEX-LEGACY-1" \
    "NBTSTAT -A $LEGACY_IP (own IP) returns HEX-LEGACY-1"

NBT_HIST="$(dos "NBTSTAT -A $HIST_IP")"
assert_contains "$NBT_HIST" "HISTORIAN-01" \
    "NBTSTAT -A $HIST_IP (real historian IP) returns HISTORIAN-01"

NBT_BURS="$(dos "NBTSTAT -A $BURS_ENT_IP")"
assert_contains "$NBT_BURS" "BURSAR-DESK" \
    "NBTSTAT -A $BURS_ENT_IP (real bursar-desk IP) returns BURSAR-DESK"

NBT_UNK="$(dos "NBTSTAT -A 10.10.99.99")"
assert_contains "$NBT_UNK" "not found|Host" "NBTSTAT unknown IP returns host not found"

# ── DIR /S: recursive file hunting ───────────────────────────────────────────

echo "[hex-legacy] DIR /S recursive file hunting"

LOG_OUT="$(dos "DIR /S *.LOG")"
assert_contains "$LOG_OUT" "ENGINEER\.LOG" "DIR /S *.LOG finds ENGINEER.LOG"
assert_contains "$LOG_OUT" "LOGBOOK"       "DIR /S *.LOG shows LOGBOOK path"

CFG_OUT="$(dos "DIR /S *.CFG")"
assert_contains "$CFG_OUT" "PLCACCS\.CFG" "DIR /S *.CFG finds PLCACCS.CFG"
assert_contains "$CFG_OUT" "PRIVATE"      "DIR /S *.CFG shows PRIVATE path"

INI_OUT="$(dos "DIR /S *.INI")"
assert_contains "$INI_OUT" "\.INI" "DIR /S *.INI finds INI files"

BAK_OUT="$(dos "DIR /S *.BAK")"
assert_contains "$BAK_OUT" "BACKUP\.BAK" "DIR /S *.BAK finds BACKUP.BAK"

CSV_OUT="$(dos "DIR /S *.CSV")"
assert_contains "$CSV_OUT" "LOGS\.CSV" "DIR /S *.CSV finds LOGS.CSV"

SIEM_OUT="$(dos "DIR /S *siemens*")"
assert_contains "$SIEM_OUT" "File Not Found|0 file" "DIR /S *siemens* returns nothing"

PRJ_OUT="$(dos "DIR /S *.PRJ")"
assert_contains "$PRJ_OUT" "File Not Found|0 file" "DIR /S *.PRJ returns nothing"

# ── FIND /I: credential and network scraping ──────────────────────────────────

echo "[hex-legacy] FIND /I credential scraping"

FIND_PASS="$(dos 'FIND /I "PASSWORDS" C:\LOGBOOK\ENGINEER.LOG')"
assert_contains "$FIND_PASS" "PASSWORDS"     "FIND locates PASSWORDS heading in ENGINEER.LOG"
assert_contains "$FIND_PASS" "ENGINEER\.LOG" "FIND output includes filename header"

# hist_read is only in the SMB public share copy (G:), not on the C: drive.
FIND_HIST="$(dos 'FIND /I "hist_read" G:\LOGBOOK\ENGINEER.LOG')"
assert_contains "$FIND_HIST" "hist_read" "FIND finds hist_read ingest credential in network share"

FIND_CRED="$(dos 'FIND /I "pass" C:\PRIVATE\PLCACCS.CFG')"
assert_contains "$FIND_CRED" "pass|spanner|Historian" "FIND finds credential lines in PLCACCS.CFG"

FIND_IP="$(dos 'FIND /I "10.10" C:\UUPL\NETWORK.TXT')"
assert_contains "$FIND_IP" "10\.10" "FIND finds IP addresses in NETWORK.TXT"

# The public SMB share carries the fuller 2019 network inventory.
# Verify the turbine PLC IP is present (links this machine to the control zone).
FIND_PLC="$(dos 'FIND /I "10.10.3.21" G:\UUPL\NETWORK.TXT')"
assert_contains "$FIND_PLC" "10\.10\.3\.21" "FIND finds turbine PLC IP in public share NETWORK.TXT"

FIND_NONE="$(dos 'FIND /I "NOTFOUNDXYZ" C:\LOGBOOK\ENGINEER.LOG')"
assert_absent "$FIND_NONE" "NOTFOUNDXYZ" "FIND with absent string returns no matching lines"

# ── TYPE: file display ────────────────────────────────────────────────────────

echo "[hex-legacy] TYPE"

TYPE_LOG="$(dos 'TYPE C:\LOGBOOK\ENGINEER.LOG')"
assert_contains "$TYPE_LOG" "SYSTEM PASSWORDS" "TYPE shows logbook password section"
assert_contains "$TYPE_LOG" "Historian2015"    "TYPE shows historian web password in logbook"

TYPE_CFG="$(dos 'TYPE C:\PRIVATE\PLCACCS.CFG')"
assert_contains "$TYPE_CFG" "spanner99"    "TYPE shows engineer SSH password in PLCACCS.CFG"
assert_contains "$TYPE_CFG" "Historian2015" "TYPE shows historian web password in PLCACCS.CFG"

# ── Output redirection ────────────────────────────────────────────────────────

echo "[hex-legacy] Output redirection"

dos 'DIR C:\ > C:\TEMP\LIST.TXT' 2>/dev/null || true
TYPE_REDIR="$(dos 'TYPE C:\TEMP\LIST.TXT')"
assert_contains "$TYPE_REDIR" "LOGBOOK|WINDOWS|UUPL" "DIR > file redirects; TYPE reads the result"

# ── Drive mapping and browsing ────────────────────────────────────────────────

echo "[hex-legacy] Drive mapping"

DIRG_OUT="$(dos "DIR G:\\")"
assert_contains "$DIRG_OUT" "LOGBOOK|UUPL" "DIR G:\\ lists the pre-mapped public share"

# ── CURL: live service access from the facade ─────────────────────────────────

echo "[hex-legacy] CURL to live services"

# G:\UUPL\NETWORK.TXT lists the historian at $HIST_IP:8080.
# Verify that IP resolves to a live service from inside the facade.
CURL_HIST="$(dos "CURL -s http://${HIST_IP}:8080/assets")"
assert_contains "$CURL_HIST" "turbine_rpm" \
    "CURL historian /assets ($HIST_IP:8080) returns live asset list"

# ── SSH auth via jump ─────────────────────────────────────────────────────────

echo "[hex-legacy] SSH authentication"

require_running "$ATTACKER"
SSH_OUT="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    root      "$LEGACY_IP" hex123)"
assert_contains "$SSH_OUT" "SSH_OK" \
    "root/hex123 authenticates via SSH (through wizzards-retreat jump)"

SSH_CMD="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    root      "$LEGACY_IP" hex123 \
    "VER")"
assert_contains "$SSH_CMD" "4\.00\.950" \
    "facade -c mode dispatches over SSH (VER returns version)"

# ── Credential chain: loot verified against real services ─────────────────────

echo "[hex-legacy] Credential chain verification"

# hist_read / history2017 appears in G:\LOGBOOK\ENGINEER.LOG (SMB public share).
# Verify it authenticates against the live historian ingest endpoint.
INGEST_OUT="$(in_container "$JUMP" curl -s --max-time 5 \
    -X POST -H 'Content-Type: application/json' \
    -u hist_read:history2017 \
    -d "{\"timestamp\":\"2026-05-18T00:00:00\",\"asset\":\"turbine_rpm\",\"value\":3000,\"unit\":\"RPM\"}" \
    "http://${HIST_IP}:8080/ingest" 2>&1)"
assert_contains "$INGEST_OUT" "ok" \
    "hist_read/history2017 (loot from G: share) authenticates against historian ingest"

# bursardesk / Octavo1 appears in G:\LOGBOOK\ENGINEER.LOG.
# Verify it reaches bursar-desk SSH via the wizzards-retreat jump.
BURS_SSH="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    bursardesk "$BURS_ENT_IP" Octavo1)"
assert_contains "$BURS_SSH" "SSH_OK" \
    "bursardesk/Octavo1 (loot from G: share) authenticates against bursar-desk SSH"

# ── SMB anonymous access ──────────────────────────────────────────────────────

echo "[hex-legacy] SMB anonymous access"

SMB_LS="$(in_container "$JUMP" smbclient //"$LEGACY_IP"/public \
    --option='client min protocol=NT1' -N -c 'ls' 2>&1)"
assert_contains "$SMB_LS" "LOGBOOK|ENGINEER|UUPL" "anonymous SMB lists public share contents"

SMB_LOG="$(in_container "$JUMP" smbclient //"$LEGACY_IP"/public \
    --option='client min protocol=NT1' -N -c 'get LOGBOOK/ENGINEER.LOG -' 2>&1)"
assert_contains "$SMB_LOG" "hist_read|SYSTEM PASSWORDS" \
    "anonymous SMB retrieves ENGINEER.LOG with credentials"

# ── FTP anonymous access ──────────────────────────────────────────────────────

echo "[hex-legacy] FTP anonymous access"

FTP_OUT="$(in_container "$JUMP" sh -c "
ftp -nv $LEGACY_IP 2>&1 <<'FTPEOF'
user anonymous anon@x
cd LOGBOOK
get ENGINEER.LOG /tmp/_eng_ftp_test.log
quit
FTPEOF
cat /tmp/_eng_ftp_test.log 2>/dev/null
rm -f /tmp/_eng_ftp_test.log
" 2>&1)"
assert_contains "$FTP_OUT" "hist_read|SYSTEM PASSWORDS" \
    "anonymous FTP retrieves ENGINEER.LOG with credentials"

summary
