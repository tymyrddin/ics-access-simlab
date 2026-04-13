#!/usr/bin/env bash
# Smoke test: inter-zone firewall policy
#
# Applies firewall.sh to the DOCKER-USER chain, then verifies:
#   - Explicitly allowed paths are reachable
#   - Everything else between zones is dropped
#
# Requires root (iptables). Skipped automatically when not root.
#
# Usage: sudo bash tests/smoke/test_firewall.sh
# Requires: make generate && make build
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

if [ "$EUID" -ne 0 ]; then
    echo "[skip] Firewall tests require root. Run: sudo bash tests/smoke/test_firewall.sh"
    exit 0
fi

NETWORKS_COMPOSE="$REPO/infrastructure/networks/docker-compose.yml"
ENT_COMPOSE="$REPO/zones/enterprise/docker-compose.yml"
OPS_COMPOSE="$REPO/zones/operational/docker-compose.yml"
CTRL_COMPOSE="$REPO/zones/control/docker-compose.yml"
FIREWALL_SH="$REPO/infrastructure/firewall.sh"

for f in "$NETWORKS_COMPOSE" "$ENT_COMPOSE" "$OPS_COMPOSE" "$CTRL_COMPOSE" "$FIREWALL_SH"; do
    require_generated "$f"
done

echo "[test_firewall] Starting all zone stacks..."

teardown() {
    echo ""
    echo "[test_firewall] Teardown..."
    docker compose -f "$CTRL_COMPOSE"     down 2>/dev/null || true
    docker compose -f "$OPS_COMPOSE"      down 2>/dev/null || true
    docker compose -f "$ENT_COMPOSE"      down 2>/dev/null || true
    docker compose -f "$NETWORKS_COMPOSE" down 2>/dev/null || true
    # Restore DOCKER-USER to pass-through default
    iptables -F DOCKER-USER 2>/dev/null || true
    iptables -A DOCKER-USER -j RETURN   2>/dev/null || true
    echo "[test_firewall] DOCKER-USER chain restored."
}
trap teardown EXIT

docker compose -f "$NETWORKS_COMPOSE" up -d 2>/dev/null
docker compose -f "$ENT_COMPOSE"      up -d 2>/dev/null
docker compose -f "$OPS_COMPOSE"      up -d 2>/dev/null
docker compose -f "$CTRL_COMPOSE"     up -d 2>/dev/null

sleep 8

echo "[test_firewall] Applying inter-zone firewall rules..."
bash "$FIREWALL_SH"

echo "[test_firewall] --- Allowed paths ---"

# Enterprise → historian web
if probe_tcp ics_enterprise 10.10.2.10 8080; then
    ok "enterprise → historian 10.10.2.10:8080 (allowed)"
else
    fail "enterprise → historian 10.10.2.10:8080 should be allowed but is blocked"
fi

# Enterprise → SCADA web
if probe_tcp ics_enterprise 10.10.2.20 8080; then
    ok "enterprise → scada 10.10.2.20:8080 (allowed)"
else
    fail "enterprise → scada 10.10.2.20:8080 should be allowed but is blocked"
fi

# Enterprise → engineering-workstation SSH
if probe_tcp ics_enterprise 10.10.2.30 22; then
    ok "enterprise → engineering-workstation 10.10.2.30:22 (allowed)"
else
    fail "enterprise → engineering-workstation 10.10.2.30:22 should be allowed but is blocked"
fi

# Engineering-workstation → control zone Modbus (probe from the ics_control network;
# engineering-workstation has a foot there at 10.10.3.100 so we can test the path)
if probe_tcp ics_operational 10.10.3.31 502; then
    ok "operational(engineering-ws) → IED relay-a 10.10.3.31:502 Modbus (allowed)"
else
    # Not a hard failure — the IED may not be listening on 502 yet or the
    # iptables rule permits from engineering-ws IP specifically. Report informatively.
    fail "operational → IED 10.10.3.31:502 Modbus not reachable (check if IED is up)"
fi

# SCADA → city RTU Modbus
if probe_tcp ics_operational 10.10.4.10 502; then
    ok "scada → rtu-dolly-1 10.10.4.10:502 Modbus (allowed)"
else
    fail "scada → rtu-dolly-1 10.10.4.10:502 Modbus should be allowed but is blocked"
fi

echo "[test_firewall] --- Blocked paths ---"

# Enterprise → control zone direct (must be blocked)
if probe_tcp_blocked ics_enterprise 10.10.3.21 502; then
    ok "enterprise → control 10.10.3.21:502 is blocked (correct)"
else
    fail "enterprise → control 10.10.3.21:502 should be blocked but is reachable"
fi

# Enterprise → WAN RTU (must be blocked)
if probe_tcp_blocked ics_enterprise 10.10.4.10 502; then
    ok "enterprise → WAN RTU 10.10.4.10:502 is blocked (correct)"
else
    fail "enterprise → WAN RTU 10.10.4.10:502 should be blocked but is reachable"
fi

# Control zone → enterprise (must be blocked)
if probe_tcp_blocked ics_control 10.10.1.10 22; then
    ok "control → enterprise 10.10.1.10:22 is blocked (correct)"
else
    fail "control → enterprise 10.10.1.10:22 should be blocked but is reachable"
fi

# WAN RTU → operational (must be blocked)
if probe_tcp_blocked ics_wan 10.10.2.10 8080; then
    ok "WAN RTU → historian 10.10.2.10:8080 is blocked (correct)"
else
    fail "WAN RTU → historian 10.10.2.10:8080 should be blocked but is reachable"
fi

summary
