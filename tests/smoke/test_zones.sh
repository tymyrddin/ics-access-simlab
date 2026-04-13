#!/usr/bin/env bash
# Smoke test: enterprise and operational zone containers
#
# Starts networks + enterprise + operational zones, then verifies:
#   - All expected containers are running
#   - Containers have correct IPs on expected networks
#   - Key services respond on expected ports
#
# Usage: bash tests/smoke/test_zones.sh
# Requires: make generate && make build (images must exist)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

NETWORKS_COMPOSE="$REPO/infrastructure/networks/docker-compose.yml"
ENT_COMPOSE="$REPO/zones/enterprise/docker-compose.yml"
OPS_COMPOSE="$REPO/zones/operational/docker-compose.yml"

for f in "$NETWORKS_COMPOSE" "$ENT_COMPOSE" "$OPS_COMPOSE"; do
    require_generated "$f"
done

echo "[test_zones] Starting stacks..."

teardown() {
    echo ""
    echo "[test_zones] Teardown..."
    docker compose -f "$OPS_COMPOSE"      down 2>/dev/null || true
    docker compose -f "$ENT_COMPOSE"      down 2>/dev/null || true
    docker compose -f "$NETWORKS_COMPOSE" down 2>/dev/null || true
}
trap teardown EXIT

docker compose -f "$NETWORKS_COMPOSE" up -d 2>/dev/null
docker compose -f "$ENT_COMPOSE"      up -d 2>/dev/null
docker compose -f "$OPS_COMPOSE"      up -d 2>/dev/null

# Give containers a moment to fully start
sleep 5

echo "[test_zones] Checking container status..."

for container in legacy-workstation enterprise-workstation historian scada-server engineering-workstation; do
    if container_running "$container"; then
        ok "container '$container' is running"
    else
        fail "container '$container' is not running"
    fi
done

echo "[test_zones] Checking IP addresses..."

check_ip() {
    local container="$1" network="$2" expected_ip="$3"
    local actual_ip
    actual_ip=$(container_ip "$container" "$network")
    if [ "$actual_ip" = "$expected_ip" ]; then
        ok "$container on $network: $actual_ip"
    else
        fail "$container on $network: expected $expected_ip, got '${actual_ip:-<not found>}'"
    fi
}

check_ip legacy-workstation     ics_enterprise  10.10.1.10
check_ip enterprise-workstation ics_enterprise  10.10.1.20
check_ip enterprise-workstation ics_operational 10.10.2.100
check_ip historian              ics_operational 10.10.2.10
check_ip scada-server           ics_operational 10.10.2.20
check_ip engineering-workstation        ics_operational 10.10.2.30

echo "[test_zones] Checking dual-homed membership..."

ent_ws_ent=$(container_ip enterprise-workstation ics_enterprise)
ent_ws_ops=$(container_ip enterprise-workstation ics_operational)
if [ -n "$ent_ws_ent" ] && [ -n "$ent_ws_ops" ]; then
    ok "enterprise-workstation is dual-homed (enterprise + operational)"
else
    fail "enterprise-workstation is not dual-homed (ent=$ent_ws_ent ops=$ent_ws_ops)"
fi

eng_ops=$(container_ip engineering-workstation ics_operational)
eng_ctrl=$(container_ip engineering-workstation ics_control)
if [ -n "$eng_ops" ] && [ -n "$eng_ctrl" ]; then
    ok "engineering-workstation is dual-homed (operational + control)"
else
    fail "engineering-workstation is not dual-homed (ops=$eng_ops ctrl=$eng_ctrl)"
fi

echo "[test_zones] Checking service ports..."

if probe_tcp ics_operational 10.10.2.10 8080; then
    ok "historian 10.10.2.10:8080 responds"
else
    fail "historian 10.10.2.10:8080 not reachable"
fi

if probe_tcp ics_operational 10.10.2.20 8080; then
    ok "scada-server 10.10.2.20:8080 responds"
else
    fail "scada-server 10.10.2.20:8080 not reachable"
fi

if probe_tcp ics_enterprise 10.10.1.10 22; then
    ok "legacy-workstation 10.10.1.10:22 (SSH) responds"
else
    fail "legacy-workstation 10.10.1.10:22 (SSH) not reachable"
fi

summary
