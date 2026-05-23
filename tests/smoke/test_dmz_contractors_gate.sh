#!/usr/bin/env bash
# contractors-gate DMZ smoke test
#
# Coverage:
#   Connectivity: port 22 reachable from internet zone
#   SSH auth: root/uupl2015 via paramiko, uid=0 confirmed
#   Network: enterprise NIC 10.10.1.30 present
#   Lateral reach: bursar-desk :22 and hex-legacy-1 :23 reachable from bastion
#   sshd_config: AllowAgentForwarding yes
#
# Usage: bash tests/smoke/test_dmz_contractors_gate.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

GW="contractors-gate"
ATTACKER="unseen-gate"

require_running "$GW"
require_running "$ATTACKER"
require_running "bursar-desk"
require_running "hex-legacy-1"

echo "[contractors-gate] Waiting for sshd (up to 30 s)..."
wait_for_port "$ATTACKER" 10.10.5.20 22 30 || { echo "[skip] contractors-gate sshd not ready"; exit 2; }

# ── Connectivity ──────────────────────────────────────────────────────────────

echo "[contractors-gate] Connectivity"

if probe_tcp internet 10.10.5.20 22; then
    ok "port 22 reachable from internet zone"
else
    fail "port 22 not reachable from internet zone"
fi

# ── SSH authentication ────────────────────────────────────────────────────────

echo "[contractors-gate] SSH authentication"

SSH_OUT="$(ssh_password_login "$ATTACKER" root 10.10.5.20 uupl2015 id)"
assert_contains "$SSH_OUT" "uid=0" "root/uupl2015 SSH login, uid=0 confirmed"

# ── Network layout ────────────────────────────────────────────────────────────

echo "[contractors-gate] Network layout"

ADDR_OUT="$(in_container "$GW" ip addr show)"
assert_contains "$ADDR_OUT" "10\.10\.5\.20" "eth1 DMZ address 10.10.5.20 present"
assert_contains "$ADDR_OUT" "10\.10\.1\.30" "eth2 enterprise address 10.10.1.30 present"

# ── Enterprise reachability ───────────────────────────────────────────────────

echo "[contractors-gate] Enterprise reachability"

if probe_tcp "$GW" 10.10.1.20 22; then
    ok "bursar-desk (10.10.1.20:22) reachable from contractors-gate"
else
    fail "bursar-desk (10.10.1.20:22) not reachable from contractors-gate"
fi

if probe_tcp "$GW" 10.10.1.10 23; then
    ok "hex-legacy-1 (10.10.1.10:23) reachable from contractors-gate"
else
    fail "hex-legacy-1 (10.10.1.10:23) not reachable from contractors-gate"
fi

# ── sshd configuration ────────────────────────────────────────────────────────

echo "[contractors-gate] sshd configuration"

SSHD_OUT="$(in_container "$GW" grep AllowAgentForwarding /etc/ssh/sshd_config)"
assert_contains "$SSHD_OUT" "yes" "sshd_config AllowAgentForwarding yes"

summary
