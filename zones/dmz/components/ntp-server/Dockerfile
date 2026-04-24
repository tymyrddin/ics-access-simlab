FROM cturra/ntp@sha256:7224d4e7c7833aabbcb7dd70c46c8a8dcccda365314c6db047b9b10403ace3bc
# NTP server with no authentication (ntpq/ntpdc open).
# Attack path: manipulate system time -> disrupt TLS cert validation and log timestamps.
# ntpd requires CAP_SYS_TIME and CAP_NET_BIND_SERVICE; root is justified here.
USER root
RUN apk add --no-cache iproute2
COPY entrypoint.sh /dmz-entrypoint.sh
RUN chmod +x /dmz-entrypoint.sh
EXPOSE 123/udp
ENTRYPOINT ["/dmz-entrypoint.sh"]
