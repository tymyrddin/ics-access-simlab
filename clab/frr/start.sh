#!/bin/sh
# UU P&L ops-ctrl-fw startup wrapper.
#   1. Apply the iptables packet-filter policy from /acl.sh.
#   2. Start sshd so the admin plane is reachable from inside the lab.
#   3. Start snmpd so the SNMP admin plane is reachable.
#   4. Hand off to the upstream FRR docker-start which boots zebra + staticd.
# /acl.sh is bind-mounted from infrastructure/routers/generated/.
set -e

if [ -f /acl.sh ]; then
    iptables -F INPUT
    iptables -F OUTPUT
    iptables -F FORWARD
    iptables -P INPUT  DROP
    iptables -P OUTPUT DROP
    iptables -P FORWARD DROP
    iptables -A INPUT  -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A OUTPUT -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # Admin plane is reachable on TCP/22 (sshd) and UDP/161 (snmpd) from
    # anywhere the FORWARD policy in /acl.sh permits a visitor to land here
    # (operational segment, etc.). Vendor stock firmware never restricts
    # these source IPs.
    iptables -A INPUT -p tcp --dport 22  -j ACCEPT
    iptables -A INPUT -p udp --dport 161 -j ACCEPT
    . /acl.sh
    echo "[ops-ctrl-fw] iptables policy applied from /acl.sh"
else
    echo "[ops-ctrl-fw] WARNING: /acl.sh not found, packet filter inactive." >&2
fi

/usr/sbin/sshd
echo "[ops-ctrl-fw] sshd up on :22 (default creds: admin/admin)"

/usr/sbin/snmpd -Lf /dev/null
echo "[ops-ctrl-fw] snmpd up on :161 (default communities: public, private)"

exec /usr/lib/frr/docker-start
