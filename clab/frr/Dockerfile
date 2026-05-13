FROM quay.io/frrouting/frr:9.1.0

# UU P&L ops-ctrl-fw, the routing fabric that replaced the iptables-only
# router. FRR carries the routes; iptables enforces the packet-filter
# policy from /acl.sh (bind-mounted at runtime from
# infrastructure/routers/generated/ops-ctrl-fw-acl.sh). sshd exposes the
# admin plane so visitors who reach the operational segment can find the
# vendor-default admin/admin and SSH straight into vtysh, the
# OT-realism-never-changed pattern.

USER root

# net-snmp adds the SNMP master agent (snmpd) and snmpwalk/get/set client
# tools. Communities live in /etc/snmp/snmpd.conf, copied below; the
# defaults (public RO, private RW) are the realistic OT vendor-default
# exposure that the lab teaches.
RUN apk add --no-cache iptables openssh net-snmp

# `admin` lands directly in vtysh on login. The enable secret in frr.conf
# gates `configure terminal` from there. Both credentials are intentionally
# weak; the lab is a maze, not a hardening exercise.
RUN adduser -D -s /usr/bin/vtysh admin \
 && echo 'admin:admin' | chpasswd \
 && adduser admin frrvty \
 && ssh-keygen -A

COPY sshd_config /etc/ssh/sshd_config
COPY snmpd.conf  /etc/snmp/snmpd.conf
COPY start.sh    /opt/start.sh
RUN chmod +x /opt/start.sh \
 && touch /etc/frr/vtysh.conf \
 && chown frr:frr /etc/frr/vtysh.conf

ENTRYPOINT ["/sbin/tini", "--", "/opt/start.sh"]
