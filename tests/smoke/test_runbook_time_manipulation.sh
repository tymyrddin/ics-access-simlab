#!/usr/bin/env bash
# Smoke test: books/time-manipulation.md
#
# guild-clock (10.10.5.30) runs cturra/ntp on UDP 123 with no authentication
# and open ntpq queries. The internet zone has direct access.
#
# Coverage (the testable stages of the runbook):
#   Stage 1a  ntpq peer list returns upstream sources (open mode 6 query)
#   Stage 1b  ntpdate -q reports an offset (server is reachable, answers v3/v4)
#   Stage 1c  no symmetric-key authentication configured
#
# Stages 3 and 4 (forging responses, observing TLS / log effects) are on-path
# attacks and are documented but not directly testable from a smoke probe.
#
# Usage: bash tests/smoke/test_runbook_time_manipulation.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="attacker-machine"
NTP="ntp_server"

for c in "$ATTACKER" "$NTP"; do
    require_running "$c"
done

# UDP services do not respond to TCP /dev/tcp probes. ntpq falls back to TCP
# mode 6 only against a tightly-configured server, so we verify readiness by
# letting the ntpq probe itself fail-and-retry rather than wait_for_port.
echo "[ntp] Stage 1a: ntpq peer list (mode 6 query, no auth)"

PEER_OUT=""
for i in 1 2 3 4 5 6; do
    PEER_OUT="$(in_container "$ATTACKER" ntpq -c "lpeers" -p 10.10.5.30 2>&1)"
    if printf '%s' "$PEER_OUT" | grep -qE '^[ \*\+\-]'; then
        break
    fi
    sleep 2
done
# A peer list line starts with a flag char (*, +, -, space, x) followed by a
# remote name. If we got nothing useful, ntp is not answering mode 6 queries.
if printf '%s' "$PEER_OUT" | grep -qE 'remote.*refid|^[ \*\+]'; then
    ok "ntpq -p returns a peer list"
else
    fail "ntpq -p returned no peer list (server may not answer mode 6)"
fi

echo "[ntp] Stage 1b: ntpdate -q reports an offset"

OFFSET_OUT="$(in_container "$ATTACKER" ntpdate -q 10.10.5.30 2>&1)"
# ntpdate's terse output looks like:
#   2026-05-09 15:49:07 (+0000) -0.001395 +/- 0.000056 10.10.5.30 s4 no-leap
# Match either the stratum tag (sN) or the offset (signed value +/- error).
assert_contains "$OFFSET_OUT" '\bs[0-9]+\b|\+/-' "ntpdate -q reports stratum/offset"

echo "[ntp] Stage 1c: no symmetric-key authentication configured"

# 'rv' (read-vars) returns a system status string. With auth configured, it
# would include 'authseqno' or non-zero auth-related fields. Without auth,
# those fields are zero or absent. We assert the response came back at all
# (mode 6 query is open) and look for auth=disabled-style markers.
RV_OUT="$(in_container "$ATTACKER" ntpq -c "rv" 10.10.5.30 2>&1)"
if [ -z "$RV_OUT" ]; then
    fail "ntpq rv returned no output (mode 6 closed)"
else
    ok "ntpq rv returns server variables (mode 6 open)"
fi

# authseqno present and non-zero implies authentication is in use.
if printf '%s' "$RV_OUT" | grep -qE 'authseqno=([1-9])'; then
    fail "authseqno is set: NTP authentication appears configured (runbook claims it is not)"
else
    ok "no active authseqno: NTP runs unauthenticated as runbook claims"
fi

summary