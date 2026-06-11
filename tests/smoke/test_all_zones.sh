#!/usr/bin/env bash
# Driver: run all zone smoke tests in sequence.
#
# Shows all output except intermediate per-script summary lines, then prints
# a named per-zone table with individual test counts and a grand total.
#
# Assumes './ctl up' has been run.
#
# Usage: bash tests/smoke/test_all_zones.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"

ZONES=(enterprise operational dmz control)
SCRIPTS=(
    test_enterprise_zone.sh
    test_operational_zone.sh
    test_dmz_zone.sh
    test_control_zone.sh
)

declare -A ZONE_PASS ZONE_FAIL ZONE_STATUS

TOTAL_PASS=0
TOTAL_FAIL=0

for i in "${!ZONES[@]}"; do
    zone="${ZONES[$i]}"
    script="${SCRIPTS[$i]}"

    echo ""
    echo "########################################"
    echo "  ZONE: $zone"
    echo "########################################"

    tmpfile=$(mktemp)

    # Disable pipefail so grep's exit code does not kill the driver.
    set +o pipefail
    bash "$REPO/tests/smoke/$script" 2>&1 | tee "$tmpfile" | \
        grep --line-buffered -Ev '^[0-9]+ passed, [0-9]+ failed$|zone tests:' || true
    set -o pipefail

    # Sum the per-script summary lines to get individual test counts.
    zp=0; zf=0
    while IFS= read -r line; do
        if [[ "$line" =~ ^([0-9]+)\ passed,\ ([0-9]+)\ failed$ ]]; then
            zp=$((zp + ${BASH_REMATCH[1]}))
            zf=$((zf + ${BASH_REMATCH[2]}))
        fi
    done < "$tmpfile"
    rm -f "$tmpfile"

    ZONE_PASS[$zone]=$zp
    ZONE_FAIL[$zone]=$zf
    TOTAL_PASS=$((TOTAL_PASS + zp))
    TOTAL_FAIL=$((TOTAL_FAIL + zf))

    if   [ "$zp" -eq 0 ] && [ "$zf" -eq 0 ]; then ZONE_STATUS[$zone]="SKIP"
    elif [ "$zf" -eq 0 ];                     then ZONE_STATUS[$zone]="PASS"
    else                                            ZONE_STATUS[$zone]="FAIL"
    fi
done

echo ""
echo "########################################"
echo ""
for zone in "${ZONES[@]}"; do
    printf "  %-14s  %4d passed, %3d failed  [%s]\n" \
        "$zone" "${ZONE_PASS[$zone]}" "${ZONE_FAIL[$zone]}" "${ZONE_STATUS[$zone]}"
done
echo ""
printf "  Total:          %4d passed, %3d failed\n" "$TOTAL_PASS" "$TOTAL_FAIL"

any_skip=0
for zone in "${ZONES[@]}"; do
    [ "${ZONE_STATUS[$zone]}" = "SKIP" ] && any_skip=1 && break
done
if [ "$any_skip" -eq 1 ]; then
    echo ""
    echo "  [SKIP] zones indicate the lab is not fully running. Run './ctl up' first."
fi

echo ""
[ "$TOTAL_FAIL" -eq 0 ] && [ "$any_skip" -eq 0 ]
