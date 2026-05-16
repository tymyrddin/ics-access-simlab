#!/usr/bin/env bash
# Driver: run all Phase 1 entry chain smoke tests.
#
# Assumes './ctl up' has been run. Each child script probes a stage of the IT
# to OT pivot the lab exposes: attacker machine to admin@home to enterprise to
# operational to control. A failed assertion is an implementation gap in the
# lab; rerun after fixing.
#
# Usage: bash tests/smoke/test_phase1.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
for t in \
    test_admin_home_pivot.sh \
    test_enterprise_to_turbine_trip.sh \
    test_bastion_enterprise_pivot.sh
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
echo "Phase 1 tests: $PASSED passed, $FAILED failed, $SKIPPED skipped."
if [ "$SKIPPED" -gt 0 ]; then
    echo "Skipped tests indicate the lab is not fully running. Run './ctl up' first."
fi
[ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]