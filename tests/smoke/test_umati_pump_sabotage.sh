#!/usr/bin/env bash
# guild-exchange (10.10.5.10:8080) runs umatiGateway pre-fix build with the
# CVE-2025-27615 unauthenticated management UI. guild-register
# (10.10.5.13:4840) is the OPC-UA server, anonymous, SecurityMode None.
#
# Coverage:
#   Stage 1  management UI reachable without credentials, no WWW-Authenticate
#   Stage 1  configured OPC endpoint visible to unauthenticated callers
#   Stage 3  OPC-UA server accepts anonymous connection
#   Stage 4  pump object readable (browse to it)
#
# Stage 5 (MQTT northbound observation) requires the gateway to have an active
# OPC connection; the umati config ships with startOPCConnection=False so the
# gateway only publishes after Stage 2's connect call. Tested separately as
# informational.
#
# Usage: bash tests/smoke/test_umati_pump_sabotage.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
HOME_BOX="wizzards-retreat"
UMATI="guild-exchange"
OPCUA="guild-register"

# Recon (curl, TCP port probe) runs from unseen-gate. OPC-UA Python
# fires from wizzards-retreat, where the opcua library lives in
# /opt/admin-env (Rincewind's admin kit).
for c in "$ATTACKER" "$HOME_BOX" "$UMATI" "$OPCUA"; do
    require_running "$c"
done

echo "[umati] Waiting for guild-exchange and guild-register..."
wait_for_port "$ATTACKER" 10.10.5.10 8080 90 || fail "guild-exchange :8080 not ready"
wait_for_port "$ATTACKER" 10.10.5.13 4840 90 || fail "guild-register :4840 not ready"

echo "[umati] Stage 1: management UI reachable without credentials"

# A protected resource would respond with 401 and a WWW-Authenticate header.
HEAD_OUT="$(in_container "$ATTACKER" curl -sI -m 5 http://10.10.5.10:8080/ 2>&1)"
assert_contains "$HEAD_OUT" "HTTP/1\\.[01] (200|301|302|307)" \
    "guild-exchange :8080 returns success/redirect (no auth challenge)"
assert_absent "$HEAD_OUT" "WWW-Authenticate" \
    "no WWW-Authenticate header (CVE-2025-27615: unauthenticated UI)"

# The runbook navigates to the OPCConnection view to read the configured
# endpoint. Different umatiGateway builds expose this differently; assert that
# the page text mentions the OPC-UA endpoint host.
GET_OUT="$(in_container "$ATTACKER" curl -sf -m 5 http://10.10.5.10:8080/ 2>&1)"
GET_OUT_OPC="$(in_container "$ATTACKER" curl -sf -m 5 http://10.10.5.10:8080/OPCConnection 2>&1)"
COMBINED="$GET_OUT$GET_OUT_OPC"
if printf '%s' "$COMBINED" | grep -q "10\\.10\\.5\\.13"; then
    ok "configured OPC endpoint (10.10.5.13) visible to unauthenticated caller"
else
    fail "configured OPC endpoint not visible in / or /OPCConnection responses"
fi

echo "[umati] Stage 3: OPC-UA server accepts anonymous connection"

# Use the python-opcua client from wizzards-retreat (/opt/admin-env).
# SecurityMode None + anonymous user connects without further setup.
OPC_OUT="$(in_container "$HOME_BOX" /opt/admin-env/bin/python3 -c "
from opcua import Client
c = Client('opc.tcp://10.10.5.13:4840')
c.session_timeout = 10000
try:
    c.connect()
except Exception as e:
    print('CONNECT_ERROR:', e); raise SystemExit(1)
try:
    objects = c.get_objects_node()
    children = objects.get_children()
    print('OPC_OK', len(children))
finally:
    c.disconnect()
" 2>&1)"
assert_contains "$OPC_OUT" "OPC_OK" "anonymous OPC-UA connect + browse Objects node"

echo "[umati] Stage 4: pump object discoverable on the OPC-UA server"

# The thin-edge demo server publishes a Demo namespace with simulator nodes.
# The runbook calls a stopPump method; precondition is finding a pump-shaped
# node. Browse the Objects subtree and search names case-insensitively.
PUMP_OUT="$(in_container "$HOME_BOX" /opt/admin-env/bin/python3 -c "
from opcua import Client
c = Client('opc.tcp://10.10.5.13:4840')
c.session_timeout = 10000
c.connect()
try:
    seen = []
    def walk(node, depth=0):
        if depth > 4: return
        for child in node.get_children():
            try:
                name = child.get_browse_name().Name
            except Exception:
                name = repr(child)
            seen.append(name)
            walk(child, depth + 1)
    walk(c.get_objects_node())
    pumpish = [n for n in seen if 'pump' in n.lower() or 'motor' in n.lower() or 'demo' in n.lower()]
    if pumpish:
        print('PUMP_FOUND', pumpish[:5])
    else:
        print('NO_PUMP names_seen=', seen[:30])
finally:
    c.disconnect()
" 2>&1)"
assert_contains "$PUMP_OUT" "PUMP_FOUND|Demo|Pump|Motor" \
    "pump-like or demo node visible on the OPC-UA server"

echo "[umati] Stage 5: MQTT northbound (gateway auto-publishes umati/v2/...)"

# The gateway is configured with startOPCConnection=True + startMqttProvider=True,
# so it publishes to clacks-relay from boot. Subscribe for a few seconds from
# wizzards-retreat (mosquitto-clients lives there) and assert a umati/v2 topic
# from this gateway appears, confirming the OPC->MQTT bridge is live.
MQTT_PROBE="$(in_container "$ATTACKER" bash -c 'exec 3<>/dev/tcp/10.10.5.12/1883 && echo MQTT_OPEN' 2>&1)"
assert_contains "$MQTT_PROBE" "MQTT_OPEN" "clacks-relay MQTT :1883 reachable from attacker"

# Wait up to ~15s total for a gateway-published topic. Publish interval is 5s.
MQTT_OUT=""
for i in 1 2 3; do
    MQTT_OUT="$(in_container "$HOME_BOX" timeout 6 mosquitto_sub -h 10.10.5.12 -p 1883 \
        -t 'umati/v2/#' -v 2>&1 | head -20)"
    if printf '%s' "$MQTT_OUT" | grep -q 'umati/v2/umati-guild-exchange/clientOnline'; then
        break
    fi
done
assert_contains "$MQTT_OUT" "umati/v2/umati-guild-exchange/clientOnline" \
    "gateway publishes clientOnline to clacks-relay (auto-connect on boot)"
assert_contains "$MQTT_OUT" "online/nsu=http_3A_2F_2Fwww.cumulocity.com;i=7" \
    "gateway publishes Pump01 operatingLevel subscription status (i=7)"

summary