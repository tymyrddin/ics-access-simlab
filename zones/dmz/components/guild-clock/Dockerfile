FROM cturra/ntp@sha256:7224d4e7c7833aabbcb7dd70c46c8a8dcccda365314c6db047b9b10403ace3bc
# NTP server with no authentication. Built on chrony (cturra/ntp). Modern OT
# distros (RHEL 8+, Ubuntu 18.04+) ship chrony as the default time daemon, so
# the recon tool of choice in the runbook is `chronyc -h 10.10.5.30 ...`,
# which speaks chrony's own command protocol on UDP/323 (not the legacy NTP
# mode-6 that ntpq uses; chrony does not speak that at all).
#
# Vendor-default leaky access: `cmdallow all` opens UDP/323 to any caller,
# `bindcmdaddress 0.0.0.0` makes chronyd listen for chronyc commands on every
# interface (default is loopback only). Combined, that lets a remote visitor
# run chronyc sources / chronyc tracking against this server with no auth.
#
# chronyd needs CAP_SYS_TIME and CAP_NET_BIND_SERVICE; root is justified.
USER root
RUN apk add --no-cache iproute2
COPY chrony.conf /etc/chrony/chrony.conf
COPY entrypoint.sh /dmz-entrypoint.sh
RUN chmod +x /dmz-entrypoint.sh
EXPOSE 123/udp 323/udp
ENTRYPOINT ["/dmz-entrypoint.sh"]
