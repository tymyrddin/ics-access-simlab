#!/usr/bin/env bash
# sorting-office (10.10.5.11) runs Neuron with an API on :7000 and a
# pre-configured MQTT northbound to clacks-relay (10.10.5.12:1883). The
# runbook's chain reaches the API from uupl-eng-ws (operational zone) since
# the Neuron API is not directly internet-reachable; the visitor pivots
# through wizzards-retreat -> eng-ws first (Phase 1 prerequisite).
#
# Coverage:
#   Stage 0  prerequisites: control zone PLC reachable, MQTT broker reachable
#   Stage 2  Neuron API reachable from eng-ws (operational zone)
#   Stage 3  admin/uupl2015 login returns a token
#   Stage 3b credential reuse: same password also works on contractors-gate
#   Stage 5b northbound MQTT broker reachable from internet zone (visitor's
#            subscribe-from-unseen-gate path)
#
# Stages 4, 5, 6 (configuring Neuron southbound + tag group + tags + observing
# MQTT messages) require state mutation that this smoke test does not perform.
# After Stage 3 returns a token, the visitor still needs to set up socat and
# Modbus south node by hand; the auth check is the smoke gate for that flow.
#
# Usage: bash tests/smoke/test_neuron_covert_exfil.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="attacker-machine"
HOME_BOX="admin-home"
ENG_WS="engineering-workstation"
NEURON="neuron_gateway"
MQTT="mqtt_dmz"
BASTION="ssh_bastion"

for c in "$ATTACKER" "$HOME_BOX" "$ENG_WS" "$NEURON" "$MQTT" "$BASTION" turbine_plc; do
    require_running "$c"
done

echo "[neuron] Waiting for chain prerequisites..."
wait_for_port "$ATTACKER" 10.10.0.10 22 30  || fail "wizzards-retreat sshd not ready"
wait_for_port "$ENG_WS"   10.10.3.21 502 30 || fail "turbine PLC :502 not ready from eng-ws"
wait_for_port "$ENG_WS"   10.10.5.11 7000 30 || fail "Neuron API :7000 not ready from eng-ws"
wait_for_port "$ATTACKER" 10.10.5.12 1883 30 || fail "clacks-relay :1883 not reachable"

echo "[neuron] Stage 2: Neuron API reachable from eng-ws (operational pivot)"

# Neuron 2.x exposes /api/v2/ping as a POST (GET returns 405). The visitor
# probes the API with whatever method the docs say; we mirror that here.
PING_CODE="$(in_container "$ENG_WS" curl -s -m 5 -o /dev/null -w '%{http_code}' \
    -X POST http://10.10.5.11:7000/api/v2/ping 2>&1)"
if [ "$PING_CODE" = "200" ]; then
    ok "Neuron POST /api/v2/ping returns 200 from eng-ws"
else
    fail "Neuron POST /api/v2/ping returned HTTP $PING_CODE"
fi

echo "[neuron] Stage 3: admin/uupl2015 login returns a token"

LOGIN_OUT="$(in_container "$ENG_WS" curl -sf -m 5 \
    -X POST http://10.10.5.11:7000/api/v2/login \
    -H 'Content-Type: application/json' \
    -d '{"name":"admin","pass":"uupl2015"}' 2>&1)"
assert_contains "$LOGIN_OUT" "token" "Neuron login returns a token field"

echo "[neuron] Stage 3b: credential reuse on contractors-gate (root/uupl2015)"

# Visitors who find one credential are expected to try it on the other DMZ
# host. The bastion test already covers root/uupl2015; assert again here so
# the credential-reuse story is anchored in this runbook's smoke too.
BAST_LOGIN="$(ssh_password_login "$ATTACKER" root 10.10.5.20 uupl2015)"
assert_contains "$BAST_LOGIN" "SSH_OK" "same uupl2015 password also unlocks contractors-gate root"

echo "[neuron] Stage 5b: clacks-relay reachable from internet zone for visitor subscribe"

# The runbook's final step is `mosquitto_sub -h 10.10.5.12 -p 1883 -t '#' -v`
# from wizzards-retreat (mosquitto-clients lives there, not on the squatted
# gateway). After Stage 4 the gateway publishes; without it the subscribe just
# hangs. We assert the broker accepts a quick connect/disconnect using
# mosquitto_sub with a short timeout, which is enough to prove the visitor's
# exit path is open.
MOSQ_OUT="$(in_container "$HOME_BOX" timeout 3 mosquitto_sub \
    -h 10.10.5.12 -p 1883 -t '#' -C 1 -W 2 2>&1 || true)"
# We do not assert on payload content (no message is required); a successful
# connect produces no error text. Connection refused or DNS errors do.
if printf '%s' "$MOSQ_OUT" | grep -qE 'Error|refused|denied|unreachable'; then
    fail "mosquitto_sub against clacks-relay failed: $MOSQ_OUT"
else
    ok "mosquitto_sub against 10.10.5.12:1883 connects (broker accepts visitor subscribe)"
fi

summary
