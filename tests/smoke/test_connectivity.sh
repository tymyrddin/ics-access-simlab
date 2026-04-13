#!/usr/bin/env bash
# Smoke test: inter-zone routing via dual-homed containers
#
# Verifies reachability without the iptables firewall applied.
# Tests that:
#   - Intra-zone containers can reach each other
#   - Dual-homed containers are reachable on both their networks
#   - Operational-zone services are reachable from the operational network
#   - Control-zone IPs are reachable from the control network
#
# Note: cross-zone routing *through* a dual-homed container (i.e. routing
# between two bridge networks via a pivoting host) requires IP forwarding to
# be enabled in the dual-homed container. These tests verify direct
# reachability within each network segment — the realistic attack path is to
# SSH into the dual-homed host and connect from there, not to route packets
# through it at Layer 3.
#
# Usage: bash tests/smoke/test_connectivity.sh
# Requires: make generate && make build
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

NETWORKS_COMPOSE="$REPO/infrastructure/networks/docker-compose.yml"
ENT_COMPOSE="$REPO/zones/enterprise/docker-compose.yml"
OPS_COMPOSE="$REPO/zones/operational/docker-compose.yml"
CTRL_COMPOSE="$REPO/zones/control/docker-compose.yml"

for f in "$NETWORKS_COMPOSE" "$ENT_COMPOSE" "$OPS_COMPOSE" "$CTRL_COMPOSE"; do
    require_generated "$f"
done

echo "[test_connectivity] Starting all zone stacks (no firewall)..."

teardown() {
    echo ""
    echo "[test_connectivity] Teardown..."
    docker compose -f "$CTRL_COMPOSE"     down 2>/dev/null || true
    docker compose -f "$OPS_COMPOSE"      down 2>/dev/null || true
    docker compose -f "$ENT_COMPOSE"      down 2>/dev/null || true
    docker compose -f "$NETWORKS_COMPOSE" down 2>/dev/null || true
}
trap teardown EXIT

docker compose -f "$NETWORKS_COMPOSE" up -d 2>/dev/null
docker compose -f "$ENT_COMPOSE"      up -d 2>/dev/null
docker compose -f "$OPS_COMPOSE"      up -d 2>/dev/null
docker compose -f "$CTRL_COMPOSE"     up -d 2>/dev/null

sleep 8

echo "[test_connectivity] Intra-zone: enterprise network..."

# legacy-workstation → enterprise-workstation (same network, both on ics_enterprise)
if probe_tcp ics_enterprise 10.10.1.20 22; then
    ok "enterprise-workstation 10.10.1.20:22 reachable from ics_enterprise"
else
    fail "enterprise-workstation 10.10.1.20:22 not reachable from ics_enterprise"
fi

if probe_tcp ics_enterprise 10.10.1.10 22; then
    ok "legacy-workstation 10.10.1.10:22 reachable from ics_enterprise"
else
    fail "legacy-workstation 10.10.1.10:22 not reachable from ics_enterprise"
fi

echo "[test_connectivity] Enterprise-workstation dual-homed reachability..."

# enterprise-workstation's ops-side IP is reachable from ics_operational
if probe_tcp ics_operational 10.10.2.100 22; then
    ok "enterprise-workstation ops-side 10.10.2.100:22 reachable from ics_operational"
else
    fail "enterprise-workstation ops-side 10.10.2.100:22 not reachable from ics_operational"
fi

echo "[test_connectivity] Intra-zone: operational network..."

if probe_tcp ics_operational 10.10.2.10 8080; then
    ok "historian 10.10.2.10:8080 reachable from ics_operational"
else
    fail "historian 10.10.2.10:8080 not reachable from ics_operational"
fi

if probe_tcp ics_operational 10.10.2.20 8080; then
    ok "scada-server 10.10.2.20:8080 reachable from ics_operational"
else
    fail "scada-server 10.10.2.20:8080 not reachable from ics_operational"
fi

if probe_tcp ics_operational 10.10.2.30 22; then
    ok "engineering-workstation 10.10.2.30:22 reachable from ics_operational"
else
    fail "engineering-workstation 10.10.2.30:22 not reachable from ics_operational"
fi

echo "[test_connectivity] Engineering-workstation dual-homed reachability..."

# engineering-workstation's ctrl-side IP is reachable from ics_control
if probe_tcp ics_control 10.10.3.100 22; then
    ok "engineering-workstation ctrl-side 10.10.3.100:22 reachable from ics_control"
else
    fail "engineering-workstation ctrl-side 10.10.3.100:22 not reachable from ics_control"
fi

summary
