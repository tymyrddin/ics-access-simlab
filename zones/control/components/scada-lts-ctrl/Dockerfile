FROM scadalts/scadalts:release-2.8.1

# Scada-LTS — control-zone SCADA/HMI (Purdue L2).
# Connects directly to field devices via Modbus through the stunnel gateway.
# Operators use this to view process state and issue control commands.
#
# Default credentials: admin / admin (never changed post-commissioning).
# Certs volume-mounted at runtime from generated certs/ directory.
# Client key made world-readable by entrypoint — HEX-5103 (risk accepted 2020).

USER root

RUN apt-get update \
 && apt-get install -y --no-install-recommends iproute2 stunnel4 \
 && rm -rf /var/lib/apt/lists/*

COPY stunnel-client.conf /run/stunnel-client/stunnel-client.conf
COPY entrypoint.sh /scadalts-entrypoint.sh
RUN chmod +x /scadalts-entrypoint.sh

EXPOSE 8080

ENTRYPOINT ["/scadalts-entrypoint.sh"]
