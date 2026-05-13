#!/usr/bin/env bash
# Driver: run all Phase 4 (L2/L3 fabric) smoke tests.
#
# Phase 1-3 cover application-plane attack chains. Phase 4 covers the
# routing fabric itself: FRR admin planes, bridge-level L2 surface,
# routing-protocol misconfig, SNMP write-community. The clab fabric
# exposes this surface; visitors with a foothold on any zone can
# probe it.
#
# Assumes './ctl up' has been run.
#
# Usage: bash tests/smoke/test_phase4.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
for t in \
    test_vtysh_credential_stuffing.sh \
    test_arp_poisoning.sh \
    test_stp_root_takeover.sh \
    test_snmp_default_community.sh
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
echo "Phase 4 tests: $PASSED passed, $FAILED failed, $SKIPPED skipped."
if [ "$SKIPPED" -gt 0 ]; then
    echo "Skipped tests indicate the lab is not fully running. Run './ctl up' first."
fi
[ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]
