#!/usr/bin/env bash
# guild-exchange DMZ smoke test
#
# Coverage:
#   Connectivity: port 8080 reachable from internet zone
#   No-auth UI: HTTP 200 on / without credentials (CVE-2025-27615)
#   OPC endpoint visible: guild-register IP in /OPCConnection response
#   guild-register reachable: port 4840 reachable from DMZ
#   MQTT publication: umati/v2/ topics appear on clacks-relay within 15 s
#
# Usage: bash tests/smoke/test_dmz_guild_exchange.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

GE="guild-exchange"
GR="guild-register"
ATTACKER="unseen-gate"
RUNNER="contractors-gate"

RELAY="clacks-relay"

require_running "$GE"
require_running "$GR"
require_running "$RELAY"
require_running "$ATTACKER"
require_running "$RUNNER"

# umatiGateway (a .NET/Kestrel app) takes up to ~3 minutes to bind port 8080
# after the container starts. Wait before probing rather than failing fast.
# wait_for_port takes a container name, not a zone alias.
echo "[guild-exchange] Waiting for port 8080 (up to 300 s)..."
if ! wait_for_port "$ATTACKER" 10.10.5.10 8080 300; then
    fail "guild-exchange :8080 did not open within 300 s"
    summary; exit 1
fi

# ── Connectivity ──────────────────────────────────────────────────────────────

echo "[guild-exchange] Connectivity"

if probe_tcp internet 10.10.5.10 8080; then
    ok "port 8080 reachable from internet zone"
else
    fail "port 8080 not reachable from internet zone"
fi

# ── No-authentication UI ──────────────────────────────────────────────────────

echo "[guild-exchange] No-auth UI"

HTTP_CODE="$(in_container "$ATTACKER" curl -s -o /dev/null -w '%{http_code}' \
    --max-time 10 http://10.10.5.10:8080/)"
assert_contains "$HTTP_CODE" "200" "/ returns HTTP 200 without credentials"

# ── OPC endpoint configuration ────────────────────────────────────────────────

echo "[guild-exchange] OPC endpoint"

OPC_OUT="$(in_container "$ATTACKER" curl -s --max-time 10 http://10.10.5.10:8080/OPCConnection)"
assert_contains "$OPC_OUT" "10\.10\.5\.13" \
    "guild-register IP (10.10.5.13) visible in /OPCConnection"

# ── guild-register reachability ───────────────────────────────────────────────

echo "[guild-exchange] guild-register"

if probe_tcp dmz 10.10.5.13 4840; then
    ok "guild-register port 4840 reachable from DMZ"
else
    fail "guild-register port 4840 not reachable from DMZ"
fi

# ── MQTT publication ──────────────────────────────────────────────────────────

echo "[guild-exchange] MQTT publication"

# guild-exchange publishes umati/v2/... to clacks-relay every 5 s.
# Wait up to 15 s for one message to arrive; -C 1 exits after receiving it.
UMATI_OUT="$(docker exec "$RELAY" timeout 15 mosquitto_sub \
    -h 127.0.0.1 -t 'umati/#' -C 1 -v 2>/dev/null || true)"
assert_contains "$UMATI_OUT" "umati/" \
    "guild-exchange publishes umati telemetry to clacks-relay"

summary
