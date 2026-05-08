#!/usr/bin/env bash
# Driver: run all Phase 1 entry chain runbook smoke tests.
#
# Assumes './ctl up' has been run. Each child script asserts against a stage of
# its corresponding runbook in books/. Failures map back to runbook line ranges,
# so a failed assertion is either an implementation gap or a runbook overclaim.
#
# Usage: bash tests/smoke/test_runbooks_phase1.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
for t in \
    test_runbook_admin_home_pivot.sh \
    test_runbook_enterprise_to_turbine_trip.sh \
    test_runbook_ssh_bastion_rce.sh
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
echo "Phase 1 runbook tests: $PASSED passed, $FAILED failed, $SKIPPED skipped."
if [ "$SKIPPED" -gt 0 ]; then
    echo "Skipped tests indicate the lab is not fully running. Run './ctl up' first."
fi
[ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]