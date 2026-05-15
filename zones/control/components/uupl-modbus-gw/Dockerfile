FROM dweomer/stunnel

# stunnel TLS-to-Modbus gateway.
# Certs are volume-mounted at runtime from the generated certs/ directory.
# Config is volume-mounted from this component directory.
# FORWARD_TARGET env var is substituted by entrypoint.sh.

RUN apk add --no-cache iproute2
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

EXPOSE 8502

ENTRYPOINT ["/entrypoint.sh"]
