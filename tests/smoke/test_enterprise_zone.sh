#!/usr/bin/env bash
# Driver: run all enterprise zone smoke tests.
#
# Covers the two enterprise zone facade hosts: hex-legacy-1 and bursar-desk.
# Both sit on 10.10.1.0/24. bursar-desk is also dual-homed into the operational
# zone (10.10.2.100), giving it the credential pivot into OT services.
#
# Assumes './ctl up' has been run.
#
# Usage: bash tests/smoke/test_enterprise_zone.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
for t in \
    test_hex_legacy_facade.sh \
    test_bursar_desk_facade.sh
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
echo "Enterprise zone tests: $PASSED passed, $FAILED failed, $SKIPPED skipped."
if [ "$SKIPPED" -gt 0 ]; then
    echo "Skipped tests indicate the lab is not fully running. Run './ctl up' first."
fi
[ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]
