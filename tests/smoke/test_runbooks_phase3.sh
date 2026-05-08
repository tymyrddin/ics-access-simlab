#!/usr/bin/env bash
# Driver: run all Phase 3 (inner-zone Stage 2/3) runbook smoke tests.
#
# Phase 1 covers IT/OT pivot chains. Phase 2 covers DMZ-direct chains plus
# neuron-covert-exfil. Phase 3 covers the operational/control zone attacks
# that come after a Phase 1 foothold.
#
# Assumes './ctl up' has been run.
#
# Usage: bash tests/smoke/test_runbooks_phase3.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
for t in \
    test_runbook_meter_modbus_read.sh \
    test_runbook_ied_relay_force_trip.sh \
    test_runbook_historian_path_traversal.sh \
    test_runbook_historian_ingest_poison.sh \
    test_runbook_stunnel_client_key_theft.sh
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
echo "Phase 3 runbook tests: $PASSED passed, $FAILED failed, $SKIPPED skipped."
if [ "$SKIPPED" -gt 0 ]; then
    echo "Skipped tests indicate the lab is not fully running. Run './ctl up' first."
fi
[ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]