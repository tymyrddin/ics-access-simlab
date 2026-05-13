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
#   Stage 3  ifAlias.2 (eth0 description) writable with community 'private'
#   Stage 4  cleanup: ifAlias.2 restored to its original value
#
# Net-SNMP locks sysContact / sysLocation / sysName as RO when those are
# declared via snmpd.conf directives. ifAlias is writable by default with
# rwcommunity, mirroring the real-world attack where a visitor re-labels
# an interface description (visible in monitoring dashboards, surprising
# the next operator who runs `show interface description`).
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
# ifAlias.2 = description of eth0 (clab out-of-band mgmt NIC, stable index).
IFALIAS_OID='1.3.6.1.2.1.31.1.1.1.18.2'

echo "[snmp] Stage 1: sysDescr readable with community 'public'"
DESCR="$(snmp_query public "$SYS_DESCR_OID")"
assert_contains "$DESCR" "UU P&L" "sysDescr discloses vendor stock firmware string"

echo "[snmp] Stage 2: sysContact readable with community 'private'"
CONTACT="$(snmp_query private "$SYS_CONTACT_OID")"
assert_contains "$CONTACT" "@uupl.am" "sysContact discloses an internal email"

echo "[snmp] Stage 3: ifAlias.2 writable with community 'private'"
ORIG_ALIAS="$(snmp_query public "$IFALIAS_OID")"
POISONED='attacker-was-here'
SET_OUT="$(snmp_query private "$IFALIAS_OID" set "$POISONED")"
assert_contains "$SET_OUT" "$POISONED" "snmpset(ifAlias.2) returns the new value"
READBACK="$(snmp_query public "$IFALIAS_OID")"
assert_contains "$READBACK" "$POISONED" "subsequent snmpget(ifAlias.2) reflects the write"

echo "[snmp] Stage 4: restore ifAlias.2"
snmp_query private "$IFALIAS_OID" set "$ORIG_ALIAS" >/dev/null
FINAL="$(snmp_query public "$IFALIAS_OID")"
if [ -z "$ORIG_ALIAS" ]; then
    # Original value was empty; readback should also be empty (no poison residue).
    assert_absent "$FINAL" "$POISONED" "ifAlias.2 back to its original empty value"
else
    assert_contains "$FINAL" "$ORIG_ALIAS" "ifAlias.2 back to original value"
fi

summary
