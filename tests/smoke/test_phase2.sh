#!/usr/bin/env bash
# Driver: run all Phase 2 (DMZ chain) smoke tests.
#
# Phase 1 covers IT/OT pivot chains (wizzards-retreat, enterprise-to-turbine-trip,
# ssh-bastion). Phase 2 covers the DMZ-direct chains plus neuron-covert-exfil
# (which depends on a Phase 1 foothold).
#
# Assumes './ctl up' has been run.
#
# Usage: bash tests/smoke/test_phase2.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
for t in \
    test_iec104_false_readings.sh \
    test_dns_poisoning.sh \
    test_time_manipulation.sh \
    test_umati_pump_sabotage.sh \
    test_neuron_covert_exfil.sh
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
echo "Phase 2 tests: $PASSED passed, $FAILED failed, $SKIPPED skipped."
if [ "$SKIPPED" -gt 0 ]; then
    echo "Skipped tests indicate the lab is not fully running. Run './ctl up' first."
fi
[ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]