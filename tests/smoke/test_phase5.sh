#!/usr/bin/env bash
# Driver: run all Phase 5 (persistence) smoke tests.
#
# Phase 1-4 cover entry, application-plane, and routing-fabric attack
# surface. Phase 5 covers what visitors do AFTER they're in: dropping
# pubkeys for password-rotation survival, hijacking existing cron payloads
# the operator already trusts, and scheduling their own tasks via the
# Windows-native schtasks surface.
#
# Assumes './ctl up' has been run.
#
# Usage: bash tests/smoke/test_phase5.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
for t in \
    test_persistence_authorized_keys.sh \
    test_persistence_cron_implant.sh \
    test_persistence_scheduled_task.sh
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
echo "Phase 5 tests: $PASSED passed, $FAILED failed, $SKIPPED skipped."
if [ "$SKIPPED" -gt 0 ]; then
    echo "Skipped tests indicate the lab is not fully running. Run './ctl up' first."
fi
[ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]
