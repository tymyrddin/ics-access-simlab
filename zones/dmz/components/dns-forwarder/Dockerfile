FROM internetsystemsconsortium/bind9:9.20
# Open recursive resolver, DNSSEC disabled.
# Attack path: cache poisoning -> MITM historian/SCADA traffic -> credential harvest.
USER root
RUN apk add --no-cache iproute2
COPY named.conf /etc/bind/named.conf
COPY entrypoint.sh /dmz-entrypoint.sh
RUN chmod +x /dmz-entrypoint.sh
EXPOSE 53/tcp 53/udp
ENTRYPOINT ["/dmz-entrypoint.sh"]
