#!/usr/bin/env bash
# Driver: run all DMZ zone smoke tests.
#
# Covers the five DMZ hosts with their own runbooks:
#   contractors-gate  10.10.5.20  SSH bastion, dual-homed into enterprise
#   sorting-office    10.10.5.11  Neuron protocol gateway
#   guild-exchange    10.10.5.10  umatiGateway OPC-UA/MQTT bridge
#   substation-rtu    10.10.5.14  IEC-104 RTU with REST API
#   clacks-relay      10.10.5.12  Mosquitto MQTT broker
#
# Assumes './ctl up' has been run.
#
# Usage: bash tests/smoke/test_dmz_zone.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
for t in \
    test_dmz_contractors_gate.sh \
    test_dmz_sorting_office.sh \
    test_dmz_guild_exchange.sh \
    test_dmz_substation_rtu.sh \
    test_dmz_clacks_relay.sh
do
    echo ""
    echo "=========================================="
    echo "  $t"
    echo "=========================================="
    bash "$REPO/tests/smoke/$t"
    rc=$?
    case "$rc" in
        0) PASSED=$((PASSED + 1)) ;;
        2) SKIPPED=$((SKIPPED + 1)) ;;
        *) FAILED=$((FAILED + 1)) ;;
    esac
done

echo ""
echo "DMZ zone tests: $PASSED passed, $FAILED failed, $SKIPPED skipped."
if [ "$SKIPPED" -gt 0 ]; then
    echo "Skipped tests indicate the lab is not fully running. Run './ctl up' first."
fi
[ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]
