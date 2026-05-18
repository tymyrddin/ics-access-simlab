FROM balabit/syslog-ng:4.11.0
# UDP 514, plaintext, no TLS.
# Attack path: sniff monitoring traffic; spoof log entries to confuse incident response.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 gosu libcap2-bin \
    && rm -rf /var/lib/apt/lists/* \
    && getent passwd syslog >/dev/null || useradd -r -s /sbin/nologin syslog \
    && mkdir -p /var/log/syslog-relay /var/run/syslog-ng /var/lib/syslog-ng \
    && chown syslog:syslog /var/log/syslog-relay /var/run/syslog-ng /var/lib/syslog-ng \
    && setcap 'cap_net_bind_service=+ep' /usr/sbin/syslog-ng
COPY syslog-ng.conf /etc/syslog-ng/syslog-ng.conf
COPY entrypoint.sh /dmz-entrypoint.sh
RUN chmod +x /dmz-entrypoint.sh
EXPOSE 514/udp
ENTRYPOINT ["/dmz-entrypoint.sh"]
