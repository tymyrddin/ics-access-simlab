#!/usr/bin/env bash
# clacks-relay DMZ smoke test
#
# Coverage:
#   Connectivity: port 1883 reachable from internet zone
#   Anonymous round-trip: publish a message and receive it back
#
# The Mosquitto binaries live on the broker container itself. The round-trip
# test runs both pub and sub inside the container rather than requiring MQTT
# client tools on any other host.
#
# Usage: bash tests/smoke/test_dmz_clacks_relay.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

RELAY="clacks-relay"
ATTACKER="unseen-gate"

require_running "$RELAY"
require_running "$ATTACKER"

# ── Connectivity ──────────────────────────────────────────────────────────────

echo "[clacks-relay] Connectivity"

if probe_tcp internet 10.10.5.12 1883; then
    ok "port 1883 reachable from internet zone"
else
    fail "port 1883 not reachable from internet zone"
fi

# ── Anonymous publish/subscribe round-trip ────────────────────────────────────

echo "[clacks-relay] Anonymous round-trip"

# Start subscriber in background, wait for it to connect, then publish.
# mosquitto_sub -C 1 exits after receiving one message.
# timeout 10 kills the subshell if the round-trip never completes.
MQTT_OUT="$(docker exec "$RELAY" timeout 10 sh -c \
    'mosquitto_sub -h 127.0.0.1 -t smoke/test -C 1 &
     sleep 1
     mosquitto_pub -h 127.0.0.1 -t smoke/test -m smoke-ping
     wait' 2>/dev/null || true)"
assert_contains "$MQTT_OUT" "smoke-ping" "anonymous publish/subscribe round-trip"

summary
