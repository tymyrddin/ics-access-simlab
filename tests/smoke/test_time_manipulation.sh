#!/usr/bin/env bash
# guild-clock (10.10.5.30) runs chrony with no authentication and `cmdallow
# all` + `bindcmdaddress 0.0.0.0`, so the chronyc command protocol on UDP/323
# is open to any caller. Chrony does not speak the legacy NTP mode-6 control
# protocol that ntpq uses; the runbook recon stage uses chronyc instead.
#
# Coverage (the testable stages of the runbook):
#   Stage 1a  chronyc sources returns the server's peer list
#   Stage 1b  chronyc tracking returns the server's time-sync state
#   Stage 1c  chronyc authdata shows no symmetric-key authentication
#   Stage 2   ssh-bastion's /etc/ntp.conf names guild-clock as its server
#
# Stages 3 and 4 (forging responses, observing TLS / log effects) are on-path
# attacks and are documented but not directly testable from a smoke probe.
#
# Usage: bash tests/smoke/test_time_manipulation.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
HOME_BOX="wizzards-retreat"
NTP="guild-clock"
BASTION="contractors-gate"

# chronyc lives on wizzards-retreat (Rincewind's admin kit), not on the
# squatted gateway. Stage 2 (NTP client config recon) runs against a DMZ
# host that uses the NTP server.
for c in "$ATTACKER" "$HOME_BOX" "$NTP" "$BASTION"; do
    require_running "$c"
done

# chrony's command protocol takes a few seconds to be ready after deploy;
# wait for the first successful chronyc response before asserting.
echo "[ntp] Stage 1a: chronyc sources returns peer list (mode-323 query, no auth)"

SOURCES_OUT=""
for i in 1 2 3 4 5 6; do
    SOURCES_OUT="$(in_container "$HOME_BOX" chronyc -h 10.10.5.30 sources 2>&1)"
    # Real response carries the column header. A timeout / refused returns
    # something like "506 Cannot talk to daemon" or no header.
    if printf '%s' "$SOURCES_OUT" | grep -qE 'MS Name/IP address'; then
        break
    fi
    sleep 2
done
if printf '%s' "$SOURCES_OUT" | grep -qE 'MS Name/IP address'; then
    ok "chronyc sources returns peer list (column header present)"
else
    fail "chronyc sources returned no peer list (UDP/323 may be closed or auth required)"
fi

echo "[ntp] Stage 1b: chronyc tracking returns server time-sync state"

# `chronyc tracking` returns Reference ID, Stratum, Ref time, Last offset,
# RMS offset, Frequency, Skew, Root delay, Root dispersion, Update interval,
# Leap status. Assert two anchor fields: Stratum (a number) and Leap status.
TRACK_OUT="$(in_container "$HOME_BOX" chronyc -h 10.10.5.30 tracking 2>&1)"
if printf '%s' "$TRACK_OUT" | grep -qE '^Stratum +: +[0-9]+'; then
    ok "chronyc tracking returns Stratum field"
else
    fail "chronyc tracking returned no Stratum field"
fi
if printf '%s' "$TRACK_OUT" | grep -qE '^Leap status'; then
    ok "chronyc tracking returns Leap status"
else
    fail "chronyc tracking returned no Leap status field"
fi

echo "[ntp] Stage 1c: chronyc authdata shows no symmetric-key authentication"

# `chronyc authdata` lists per-source authentication configuration. With no
# `keyfile` directive in chrony.conf, the response has the column header but
# no rows. With auth configured, each source line shows KeyID + Type.
AUTHDATA_OUT="$(in_container "$HOME_BOX" chronyc -h 10.10.5.30 authdata 2>&1)"
if printf '%s' "$AUTHDATA_OUT" | grep -qE 'Name/IP address.*Mode +KeyID'; then
    ok "chronyc authdata returns response (UDP/323 open)"
else
    fail "chronyc authdata returned no response"
fi
# A configured key ID would appear as a non-zero numeric in the KeyID column
# of any source row. With no key, only the LOCAL source appears (or nothing)
# and its KeyID is 0.
if printf '%s' "$AUTHDATA_OUT" | grep -qE '^[^=]+ +(NTS|SYM) +[1-9]'; then
    fail "chronyc authdata shows configured auth (runbook claims it is not)"
else
    ok "no active key IDs: NTP runs unauthenticated as runbook claims"
fi

echo "[ntp] Stage 2: DMZ client config names guild-clock"

# Runbook: 'cat /etc/ntpsec/ntp.conf | grep server' on a DMZ host. ssh-bastion
# ships /etc/ntp.conf with 'server 10.10.5.30 iburst' so the recon find is
# real.
BASTION_NTP_CONF="$(in_container "$BASTION" cat /etc/ntp.conf 2>&1)"
assert_contains "$BASTION_NTP_CONF" "server +10\\.10\\.5\\.30" \
    "bastion /etc/ntp.conf names guild-clock (10.10.5.30) as its NTP server"

summary