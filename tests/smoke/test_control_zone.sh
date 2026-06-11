#!/usr/bin/env bash
# Driver: run all control zone smoke tests.
#
# Covers the control zone hosts:
#   hex-turbine-plc   10.10.3.21  turbine PLC (Modbus, IEC-104, DNP3, OPC-UA, SNMP)
#   uupl-relay-a      10.10.3.31  protective relay IED A (Modbus, HTTP, SNMP, MQTT)
#   uupl-relay-b      10.10.3.32  protective relay IED B (Modbus, HTTP, SNMP, MQTT)
#   uupl-hmi          10.10.3.10  FUXA HMI (unauthenticated project read/write)
#
# The process test is last: it is the slowest and perturbs live plant state.
#
# Assumes './ctl up' has been run.
#
# Usage: bash tests/smoke/test_control_zone.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
for t in \
    test_hex_turbine_plc.sh \
    test_uupl_relay.sh \
    test_uupl_hmi.sh \
    test_control_zone_process.sh
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
echo "Control zone tests: $PASSED passed, $FAILED failed, $SKIPPED skipped."
if [ "$SKIPPED" -gt 0 ]; then
    echo "Skipped tests indicate the lab is not fully running. Run './ctl up' first."
fi
[ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]
