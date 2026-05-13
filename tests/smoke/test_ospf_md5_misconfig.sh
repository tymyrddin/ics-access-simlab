#!/usr/bin/env bash
# L3 surface probe. OSPF auth is the realistic OT hardening control. When
# operators turn it on, the classic misconfiguration is enabling MD5 on
# one router but typing the wrong key (or forgetting to update) the peer.
# Adjacency silently dies after dead-time; routes the dead adjacency was
# carrying age out. A visitor with vtysh foothold can trigger this DoS
# without writing a single packet: just add auth to one side.
#
# Coverage:
#   Stage 1  baseline: adjacency is Full with no auth (NBMA fabric)
#   Stage 2  visitor adds MD5 auth on inet-dmz-fw eth1; adjacency drops
#   Stage 3  visitor adds matching MD5 on dmz-ent-fw eth1; adjacency restores
#   Stage 4  cleanup: remove MD5 from both sides
#
# Usage: bash tests/smoke/test_ospf_md5_misconfig.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="attacker-machine"
ROUTER_A="10.10.0.200"   # inet-dmz-fw
ROUTER_B="10.10.5.201"   # dmz-ent-fw
MD5_KEY="uupl-ospf-2015"

require_running "$ATTACKER"
require_running "inet-dmz-fw"
require_running "dmz-ent-fw"

# vtysh helper: open shell, send config lines, capture trailing show-run output.
vtysh_apply() {
    local host="$1" snippet="$2"
    docker exec "$ATTACKER" "$SSH_RUNNER_PY" -c "
import paramiko, time
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('$host', username='admin', password='admin', timeout=5,
          allow_agent=False, look_for_keys=False)
chan = c.invoke_shell()
def drain(t=0.4):
    time.sleep(t); out = b''
    while chan.recv_ready(): out += chan.recv(16384)
    return out.decode('utf-8', 'replace')
drain(0.5)
for line in '''$snippet'''.strip().splitlines():
    chan.send(line + '\n')
    drain(0.2)
chan.send('end\n'); drain(0.3)
chan.send('show running-config\n')
print(drain(0.6))
c.close()
" 2>&1
}

# Polling helper: returns 'Full' when peer is Full, 'NotFull' otherwise.
adjacency_state() {
    local nbr_id="$1"
    local out
    out="$(ssh_password_login "$ATTACKER" admin "$ROUTER_A" admin "show ip ospf neighbor $nbr_id")"
    if echo "$out" | grep -qE '\bFull\b'; then
        echo Full
    else
        echo NotFull
    fi
}

# Wait until adjacency reaches target state (Full / NotFull), up to N seconds.
wait_for_adjacency() {
    local target="$1" timeout="$2"
    local i=0
    while [ "$i" -lt "$timeout" ]; do
        [ "$(adjacency_state 2.2.2.2)" = "$target" ] && return 0
        sleep 1
        i=$((i + 1))
    done
    return 1
}

echo "[ospf-md5] Stage 1: baseline adjacency to dmz-ent-fw is Full"
wait_for_adjacency Full 60 || fail "baseline adjacency to dmz-ent-fw never reached Full"
ok "inet-dmz-fw <-> dmz-ent-fw adjacency is Full at start"

echo "[ospf-md5] Stage 2: visitor adds MD5 on inet-dmz-fw only; adjacency drops"
vtysh_apply "$ROUTER_A" "configure terminal
interface eth1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 $MD5_KEY" >/dev/null
# Dead interval is 40s. Allow up to 60s for the peer to mark us down.
wait_for_adjacency NotFull 60 || fail "adjacency stayed Full despite one-sided MD5; auth mismatch did not break it"
ok "adjacency dropped after one-sided MD5 (visitor's DoS-by-misconfig works)"

echo "[ospf-md5] Stage 3: matching MD5 on dmz-ent-fw restores adjacency"
vtysh_apply "$ROUTER_B" "configure terminal
interface eth1
 ip ospf authentication message-digest
 ip ospf message-digest-key 1 md5 $MD5_KEY" >/dev/null
wait_for_adjacency Full 60 || fail "adjacency did not recover after matching MD5 on peer"
ok "adjacency restored once both sides agree on the MD5 key"

echo "[ospf-md5] Stage 4: cleanup, remove MD5 from both sides"
vtysh_apply "$ROUTER_A" "configure terminal
interface eth1
 no ip ospf message-digest-key 1
 no ip ospf authentication" >/dev/null
vtysh_apply "$ROUTER_B" "configure terminal
interface eth1
 no ip ospf message-digest-key 1
 no ip ospf authentication" >/dev/null
wait_for_adjacency Full 60 || fail "adjacency did not return after MD5 removal"
ok "no-auth adjacency reformed; cleanup complete"

summary
