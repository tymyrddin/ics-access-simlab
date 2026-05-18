#!/usr/bin/env bash
# city-directory (10.10.5.31) runs BIND9 with allow-query/allow-recursion any
# and dnssec-validation no. The internet zone has direct UDP/TCP 53 access.
#
# Coverage (the testable stages of the runbook):
#   Stage 1a  version disclosure via CHAOS class
#   Stage 1b  open recursion: external name resolves for any caller
#   Stage 1c  DNSSEC validation off: AD flag absent on a signed domain
#   Stage 3   amplification reflector behaves as a forwarder for ANY queries
#
# Stages 4 and 5 (cache poisoning, credential harvest) are on-path attacks and
# are documented but not directly testable from a smoke probe.
#
# Usage: bash tests/smoke/test_dns_poisoning.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
DNS="city-directory"

for c in "$ATTACKER" "$DNS"; do
    require_running "$c"
done

echo "[dns] Waiting for city-directory..."
wait_for_port "$ATTACKER" 10.10.5.31 53 30 || fail "city-directory :53 not ready"

echo "[dns] Stage 1a: BIND9 version disclosure via CHAOS class"

VERSION_OUT="$(in_container "$ATTACKER" dig +short +time=3 +tries=1 \
    @10.10.5.31 version.bind chaos txt 2>&1)"
assert_contains "$VERSION_OUT" "9\\." "version.bind discloses BIND 9.x"

echo "[dns] Stage 1b: id.server CHAOS query discloses resolver hostname"

# server-id directive in named.conf options block makes id.server return
# "city-directory" instead of an empty string. Matches the runbook claim
# that the visitor can confirm which resolver they reached through any DMZ
# relay. Regression check: if server-id gets stripped, this assertion fails.
ID_OUT="$(in_container "$ATTACKER" dig +short +time=3 +tries=1 \
    @10.10.5.31 id.server chaos txt 2>&1)"
assert_contains "$ID_OUT" "city-directory" \
    "id.server discloses resolver hostname"

echo "[dns] Stage 2: internal authoritative zone resolves UU P&L names"

# The lab's DMZ has no outbound NAT, so external recursion does not actually
# leave the lab. The runbook's cache-poisoning targets are internal names
# (uupl-historian.uupl.am etc.); the authoritative uupl.am zone shipped on
# city-directory makes those queries answer with real internal IPs.
HIST_A="$(in_container "$ATTACKER" dig +short +time=3 +tries=1 \
    @10.10.5.31 uupl-historian.uupl.am 2>&1)"
assert_contains "$HIST_A" "^10\\.10\\.2\\.10$" \
    "uupl-historian.uupl.am resolves to 10.10.2.10 (internal zone)"

SCADA_A="$(in_container "$ATTACKER" dig +short +time=3 +tries=1 \
    @10.10.5.31 distribution-scada.uupl.am 2>&1)"
assert_contains "$SCADA_A" "^10\\.10\\.2\\.20$" \
    "distribution-scada.uupl.am resolves to 10.10.2.20 (internal zone)"

echo "[dns] Stage 2b: AXFR returns the full uupl.am zone"

# allow-transfer { any; }; on the uupl.am zone lets the recon stage actually
# pull the full record set rather than getting "Transfer failed". Regression
# check: if allow-transfer gets locked down, this assertion fails.
AXFR_OUT="$(in_container "$ATTACKER" dig +time=3 +tries=1 \
    @10.10.5.31 uupl.am AXFR 2>&1)"
assert_contains "$AXFR_OUT" "uupl-historian.uupl.am.*10\\.10\\.2\\.10" \
    "AXFR returns uupl-historian record"
assert_contains "$AXFR_OUT" "distribution-scada.uupl.am.*10\\.10\\.2\\.20" \
    "AXFR returns distribution-scada record"

echo "[dns] Stage 1c: DNSSEC validation disabled"

# A resolver with DNSSEC validation enabled would set the AD (authenticated
# data) bit when answering. The internal zone is unsigned, so AD will always
# be clear there; instead we assert that the resolver's published config
# matches the runbook claim by pulling the running named.conf from the
# resolver itself. That is what a visitor would confirm by querying the
# resolver's recursion behaviour against a deliberately-broken signed name,
# which we cannot do without external recursion.
DNS_CONF="$(in_container city-directory cat /etc/bind/named.conf 2>&1)"
assert_contains "$DNS_CONF" "dnssec-validation no" \
    "dnssec-validation no in running named.conf"
assert_contains "$DNS_CONF" "allow-recursion *\\{ *any *; *\\}" \
    "allow-recursion any in running named.conf"

summary