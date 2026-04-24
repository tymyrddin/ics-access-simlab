FROM scadalts/scadalts:release-2.8.1

# Scada-LTS — open-source SCADA/HMI (Mango Automation base).
# Runs on port 8080. Default credentials: admin / admin.
# Connects to turbine PLC via stunnel TLS gateway.
#
# Certs are volume-mounted at runtime from the generated certs/ directory.
# Client key is made world-readable at container start by entrypoint.sh —
# see HEX-5103 (OPEN, risk accepted 2020).

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 stunnel4 \
 && rm -rf /var/lib/apt/lists/*

COPY stunnel-client.conf /run/stunnel-client/stunnel-client.conf
COPY entrypoint.sh /scadalts-entrypoint.sh
RUN chmod +x /scadalts-entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/scadalts-entrypoint.sh"]
