#!/usr/bin/env bash
# Shared helpers for smoke test scripts.
# Source this file: source "$(dirname "$0")/lib.sh"

PASS=0
FAIL=0

ok() {
    echo "  ✔ $*"
    PASS=$((PASS + 1))
}

fail() {
    echo "  ✗ $*"
    FAIL=$((FAIL + 1))
}

summary() {
    echo ""
    echo "$PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ]
}

# Guard: compose files must already exist (run 'make generate' first).
require_generated() {
    local file="$1"
    if [ ! -f "$file" ]; then
        echo "[skip] Required generated file not found: $file"
        echo "       Run 'make generate' before running smoke tests."
        exit 0
    fi
}

# TCP connectivity probe using a throw-away alpine container.
# Usage: probe_tcp <network> <host> <port>
# Returns 0 if reachable, non-zero otherwise.
probe_tcp() {
    local network="$1" host="$2" port="$3"
    docker run --rm --network "$network" alpine \
        nc -z -w3 "$host" "$port" 2>/dev/null
}

# Inverse probe — succeeds when the port is NOT reachable.
# Usage: probe_tcp_blocked <network> <host> <port>
probe_tcp_blocked() {
    local network="$1" host="$2" port="$3"
    ! docker run --rm --network "$network" alpine \
        nc -z -w3 "$host" "$port" 2>/dev/null
}

# UDP probe via SNMP GET (OID sysDescr).
# Usage: probe_udp_snmp <network> <host> <community>
# Returns 0 if we get a response, non-zero otherwise.
probe_udp_snmp() {
    local network="$1" host="$2" community="${3:-public}"
    docker run --rm --network "$network" \
        --entrypoint snmpget \
        elcolio/net-snmp \
        -v2c -c "$community" -t 3 -r 1 \
        "$host" 1.3.6.1.2.1.1.1.0 2>/dev/null
}

# Check a container is running.
# Usage: container_running <name>
container_running() {
    local name="$1"
    [ "$(docker inspect --format '{{.State.Running}}' "$name" 2>/dev/null)" = "true" ]
}

# Get a container's IP on a given network.
# Usage: container_ip <name> <network>
container_ip() {
    local name="$1" network="$2"
    docker inspect --format \
        "{{(index .NetworkSettings.Networks \"$network\").IPAddress}}" \
        "$name" 2>/dev/null
}
