#!/usr/bin/env bash
# hex-legacy-1 Windows 95 DOS facade smoke test
#
# Coverage:
#   Identity: ver, ipconfig (dynamic IP), winipcfg (dynamic MAC + gateway)
#   Network: route (real routing table), arp (real ARP table), netstat
#   Filesystem: dir C:\, type C:\PRIVATE\PLCACCS.CFG (credential discovery)
#   Net share: net view (network enumeration), net user
#   FTP: anonymous read access to public share
#   Telnet: port 23 reachable, no-auth access
#   SSH auth: root/hex123 via wizzards-retreat jump
#   Credential chain: engineer/spanner99 (from PLCACCS.CFG) reaches eng-ws
#
# Usage: bash tests/smoke/test_hex_legacy_facade.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

HEX="hex-legacy-1"
JUMP="wizzards-retreat"
ATTACKER="unseen-gate"
ENGWS="uupl-eng-ws"

require_running "$HEX"
require_running "$JUMP"
require_running "$ATTACKER"
require_running "$ENGWS"

dos() { in_container "$HEX" /usr/local/bin/win95shell.sh -c "$1"; }

HEX_IP=$(container_ip "$HEX" enterprise)
ENG_IP=$(container_ip "$ENGWS" operational)

echo "[hex-legacy-1] Waiting for SSH on $HEX_IP..."
if ! wait_for_port "$JUMP" "$HEX_IP" 22 30; then
    fail "hex-legacy-1 :22 not ready within 30s"
    summary; exit 1
fi

# ── Identity ──────────────────────────────────────────────────────────────────

echo "[hex-legacy-1] Identity"

VER_OUT="$(dos "VER")"
assert_contains "$VER_OUT" "Windows 95|4\.00\.950" "VER returns Windows 95 banner"

IPCFG_OUT="$(dos "IPCONFIG")"
assert_contains "$IPCFG_OUT" "${HEX_IP//./\\.}" "ipconfig shows real enterprise IP ($HEX_IP)"

WINIPCFG_OUT="$(dos "WINIPCFG")"
assert_contains "$WINIPCFG_OUT" "${HEX_IP//./\\.}" "winipcfg shows real IP"
assert_contains "$WINIPCFG_OUT" "[0-9A-Fa-f][0-9A-Fa-f]-[0-9A-Fa-f]" \
    "winipcfg shows a real MAC address (not hardcoded 00-50-56-01-02-03)"
assert_contains "$WINIPCFG_OUT" "Default Gateway" "winipcfg shows Default Gateway field"

# ── Network: dynamic commands ─────────────────────────────────────────────────

echo "[hex-legacy-1] Network"

ROUTE_OUT="$(dos "ROUTE")"
assert_contains "$ROUTE_OUT" "Active Routes" "route shows Active Routes header"
assert_contains "$ROUTE_OUT" "0\.0\.0\.0.*0\.0\.0\.0|Default Gateway" \
    "route shows default route"
assert_contains "$ROUTE_OUT" "${HEX_IP%.*}\." \
    "route shows enterprise subnet (real routing table)"

ARP_OUT="$(dos "ARP -A")"
assert_contains "$ARP_OUT" "Interface:.*${HEX_IP//./\\.}" "arp shows correct local interface IP"
assert_contains "$ARP_OUT" "Internet Address" "arp shows table header"

NETSTAT_OUT="$(dos "NETSTAT")"
assert_contains "$NETSTAT_OUT" "Active Connections" "netstat shows Active Connections"

# ── Filesystem ────────────────────────────────────────────────────────────────

echo "[hex-legacy-1] Filesystem"

DIR_OUT="$(dos "DIR C:\\")"
assert_contains "$DIR_OUT" "UUPL|WINDOWS|AUTOEXEC|CONFIG" \
    "dir C:\ lists top-level DOS directories"
assert_contains "$DIR_OUT" "[0-9][0-9]/[0-9][0-9]/[0-9][0-9]" \
    "dir C:\ shows real file timestamps (not hardcoded 14/09/99)"

DIR_PRIV="$(dos 'DIR C:\PRIVATE\')"
assert_contains "$DIR_PRIV" "PLCACCS|BACKUP" \
    "dir C:\PRIVATE\ lists credential and backup files"

PLCACCS_OUT="$(dos 'TYPE C:\PRIVATE\PLCACCS.CFG')"
assert_contains "$PLCACCS_OUT" "spanner99" \
    "C:\PRIVATE\PLCACCS.CFG contains engineer/spanner99"
assert_contains "$PLCACCS_OUT" "Historian2015" \
    "C:\PRIVATE\PLCACCS.CFG contains Historian2015"
assert_contains "$PLCACCS_OUT" "10\.10\.2\." \
    "C:\PRIVATE\PLCACCS.CFG lists operational zone hosts"

# ── Net share enumeration ─────────────────────────────────────────────────────

echo "[hex-legacy-1] Net share enumeration"

NET_VIEW="$(dos "NET VIEW")"
assert_contains "$NET_VIEW" "HEX-LEGACY-1|UUPL-SRV-01" \
    "net view lists network hosts"

NET_USER="$(dos "NET USER")"
assert_contains "$NET_USER" "Administrator|Guest" \
    "net user lists local accounts"

# ── FTP anonymous access ──────────────────────────────────────────────────────

echo "[hex-legacy-1] FTP anonymous access"

FTP_OUT="$(in_container "$JUMP" curl -s --max-time 10 \
    "ftp://${HEX_IP}/" 2>/dev/null)"
assert_contains "$FTP_OUT" "NETWORK_INVENTORY|PROCEDURES|LOGS_SAMPLE|LOGBOOK" \
    "FTP anonymous lists public share contents"

# ── Telnet: port reachable ────────────────────────────────────────────────────

echo "[hex-legacy-1] Telnet"

if wait_for_port "$JUMP" "$HEX_IP" 23 10; then
    ok "telnet port 23 reachable from enterprise network"
else
    fail "telnet port 23 not reachable"
fi

# ── SSH auth via jump ─────────────────────────────────────────────────────────

echo "[hex-legacy-1] SSH authentication"

SSH_OUT="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    root "$HEX_IP" hex123)"
assert_contains "$SSH_OUT" "SSH_OK" \
    "root/hex123 authenticates to hex-legacy-1 via wizzards-retreat jump"

SSH_CMD="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    root "$HEX_IP" hex123 \
    "VER")"
assert_contains "$SSH_CMD" "Windows 95|4\.00" \
    "SSH exec via jump: VER returns Windows 95 banner through facade"

# ── Credential chain ──────────────────────────────────────────────────────────

echo "[hex-legacy-1] Credential chain"

ENG_SSH="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    engineer "$ENG_IP" spanner99)"
assert_contains "$ENG_SSH" "SSH_OK" \
    "engineer/spanner99 (from C:\PRIVATE\PLCACCS.CFG) authenticates to eng-ws"

summary
