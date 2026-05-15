#!/usr/bin/env bash
# Verifies that contractors-gate (10.10.5.20) is reachable from the internet
# zone, accepts root/uupl2015, is dual-homed into ics_enterprise, and exposes
# the enterprise zone for lateral movement.
#
# Coverage:
#   Stage 1  bastion 22/tcp open, banner is OpenSSH 9.2p1 Debian
#   Stage 2  ssh root/uupl2015 logs in; ip addr shows DMZ + enterprise NIC
#   Stage 3  enterprise zone hosts reachable from bastion
#   Stage 4  AllowAgentForwarding yes is configured
#
# Usage: bash tests/smoke/test_ssh_bastion_rce.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
BASTION="contractors-gate"

for c in "$ATTACKER" "$BASTION"; do
    require_running "$c"
done

echo "[ssh-bastion] Waiting for bastion sshd..."
wait_for_port "$ATTACKER" 10.10.5.20 22 30 || fail "contractors-gate sshd not ready"

echo "[ssh-bastion] Stage 1a: target reachable from internet zone"

NMAP_OUT="$(in_container "$ATTACKER" nmap -sV -p 22 10.10.5.20 2>&1)"
assert_contains "$NMAP_OUT" "22/tcp +open"  "contractors-gate 22/tcp open"
assert_contains "$NMAP_OUT" "OpenSSH 9\.2p1" "banner reports OpenSSH 9.2p1"
assert_contains "$NMAP_OUT" "Debian"         "banner reports Debian build (vulnerable to CVE-2024-6387)"

echo "[ssh-bastion] Stage 1b: explicit banner grab via netcat"

# Runbook: 'echo | nc 10.10.5.20 22' returns the SSH banner directly. The
# runbook specifically uses this because ssh itself does not print the banner
# to stderr without -v.
NC_BANNER="$(in_container "$ATTACKER" sh -c 'echo | nc -w 3 10.10.5.20 22 2>&1' || true)"
assert_contains "$NC_BANNER" "SSH-2\.0-OpenSSH" \
    "nc banner grab returns SSH-2.0-OpenSSH protocol string"

echo "[ssh-bastion] Stage 2: root/uupl2015 logs in"

ROOT_LOGIN="$(ssh_password_login "$ATTACKER" root 10.10.5.20 uupl2015)"
assert_contains "$ROOT_LOGIN" "SSH_OK" "ssh root/uupl2015 authenticates"

echo "[ssh-bastion] Stage 2b: dual-homed (DMZ + enterprise NIC)"

DMZ_IP="$(container_ip "$BASTION" ics_dmz)"
ENT_IP="$(container_ip "$BASTION" ics_enterprise)"
if [ "$DMZ_IP" = "10.10.5.20" ]; then
    ok "bastion DMZ NIC at 10.10.5.20"
else
    fail "bastion DMZ NIC: expected 10.10.5.20, got '${DMZ_IP:-<none>}'"
fi
if [ "$ENT_IP" = "10.10.1.30" ]; then
    ok "bastion enterprise NIC at 10.10.1.30"
else
    fail "bastion enterprise NIC: expected 10.10.1.30, got '${ENT_IP:-<none>}'"
fi

# bash root has a real shell, so paramiko exec_command returns useful output.
IPADDR="$(ssh_password_login "$ATTACKER" root 10.10.5.20 uupl2015 'ip -4 -o addr show')"
assert_contains "$IPADDR" "10\.10\.5\.20"  "bastion sees own DMZ IP via SSH session"
assert_contains "$IPADDR" "10\.10\.1\.30"  "bastion sees own enterprise IP via SSH session"

echo "[ssh-bastion] Stage 3: enterprise zone reachable from bastion"

NC_LEGACY="$(ssh_password_login "$ATTACKER" root 10.10.5.20 uupl2015 \
    'bash -c "echo > /dev/tcp/10.10.1.10/22 && echo ok || echo fail"')"
NC_BURSAR="$(ssh_password_login "$ATTACKER" root 10.10.5.20 uupl2015 \
    'bash -c "echo > /dev/tcp/10.10.1.20/22 && echo ok || echo fail"')"
assert_contains "$NC_LEGACY"  "ok" "bastion can connect to 10.10.1.10:22"
assert_contains "$NC_BURSAR"  "ok" "bastion can connect to 10.10.1.20:22"

echo "[ssh-bastion] Stage 4: AllowAgentForwarding configured"

SSHD_CFG="$(in_container "$BASTION" cat /etc/ssh/sshd_config 2>&1)"
assert_contains "$SSHD_CFG" "^AllowAgentForwarding yes" "sshd_config has AllowAgentForwarding yes"
assert_contains "$SSHD_CFG" "^PermitRootLogin yes"      "sshd_config has PermitRootLogin yes"

echo "[ssh-bastion] Stage 5: rsyslog forwarding to scribes-post (informational)"

if [ -n "$(in_container "$BASTION" pgrep rsyslogd 2>&1)" ]; then
    ok "rsyslogd running on bastion"
else
    fail "rsyslogd not running on bastion (auth events not forwarded)"
fi

summary