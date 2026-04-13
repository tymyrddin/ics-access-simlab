#!/usr/bin/env bash
# Smoke test: shared Docker networks
#
# Verifies that all four zone networks are created with correct names and subnets.
# Does NOT require Docker images to be built — only the networks stack.
#
# Usage: bash tests/smoke/test_networks.sh
# Requires: make generate (compose files must exist)
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

NETWORKS_COMPOSE="$REPO/infrastructure/networks/docker-compose.yml"
require_generated "$NETWORKS_COMPOSE"

echo "[test_networks] Starting networks stack..."

teardown() {
    echo ""
    echo "[test_networks] Teardown..."
    docker compose -f "$NETWORKS_COMPOSE" down 2>/dev/null || true
}
trap teardown EXIT

docker compose -f "$NETWORKS_COMPOSE" up -d 2>/dev/null

echo "[test_networks] Checking network names..."

EXPECTED_NETWORKS=(
    "ics_internet"
    "ics_enterprise"
    "ics_operational"
    "ics_control"
    "ics_wan"
)

EXPECTED_SUBNETS=(
    "10.10.0.0/24"
    "10.10.1.0/24"
    "10.10.2.0/24"
    "10.10.3.0/24"
    "10.10.4.0/24"
)

for net in "${EXPECTED_NETWORKS[@]}"; do
    if docker network ls --format '{{.Name}}' | grep -q "^${net}$"; then
        ok "network '$net' exists"
    else
        fail "network '$net' not found"
    fi
done

echo "[test_networks] Checking network subnets..."

for i in "${!EXPECTED_NETWORKS[@]}"; do
    net="${EXPECTED_NETWORKS[$i]}"
    expected_subnet="${EXPECTED_SUBNETS[$i]}"
    actual_subnet=$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$net" 2>/dev/null)
    if [ "$actual_subnet" = "$expected_subnet" ]; then
        ok "network '$net' subnet is $actual_subnet"
    else
        fail "network '$net' subnet: expected $expected_subnet, got '${actual_subnet:-<not found>}'"
    fi
done

summary
