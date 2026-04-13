FROM ubuntu/bind9:9.20-26.04_edge
# Open recursive resolver — DNSSEC disabled.
# Attack path: cache poisoning → MITM historian/SCADA traffic → credential harvest.
COPY named.conf /etc/bind/named.conf
EXPOSE 53/tcp 53/udp
