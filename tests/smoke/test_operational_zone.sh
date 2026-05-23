#!/usr/bin/env bash
# Driver: run all operational zone smoke tests.
#
# Covers the three operational zone facade hosts:
#   distribution-scada  10.10.2.20  WinServer 2016, SCADA + stunnel client key
#   uupl-historian      10.10.2.10  WinServer 2019, SQLi + path traversal
#   uupl-eng-ws         10.10.2.30  Win10 LTSC, dual-homed into control zone
#
# Assumes './ctl up' has been run.
#
# Usage: bash tests/smoke/test_operational_zone.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

PASSED=0
FAILED=0
SKIPPED=0
for t in \
    test_distribution_scada_facade.sh \
    test_uupl_historian_facade.sh \
    test_uupl_eng_ws_facade.sh
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
echo "Operational zone tests: $PASSED passed, $FAILED failed, $SKIPPED skipped."
if [ "$SKIPPED" -gt 0 ]; then
    echo "Skipped tests indicate the lab is not fully running. Run './ctl up' first."
fi
[ "$FAILED" -eq 0 ] && [ "$SKIPPED" -eq 0 ]
