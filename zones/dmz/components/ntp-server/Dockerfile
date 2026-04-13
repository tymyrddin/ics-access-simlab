FROM cturra/ntp@sha256:7224d4e7c7833aabbcb7dd70c46c8a8dcccda365314c6db047b9b10403ace3bc
# NTP server with no authentication (ntpq/ntpdc open).
# Attack path: manipulate system time → disrupt TLS cert validation and log timestamps.
EXPOSE 123/udp
