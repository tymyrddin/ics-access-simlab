FROM ghcr.io/umati/umatigateway:pr-375
# Pre-fix build — web UI on :8080 has no authentication (CVE-2025-27615).
# OPC connection configured to guild-register (10.10.5.13:4840), SecurityMode None.
# MQTT northbound configured to clacks-relay (10.10.5.12:1883).
# Connections are set to startOPCConnection=False so the app starts without
# requiring live peer connectivity at boot time. The attacker accesses the
# no-auth UI, reads the configured OPC server endpoint, then attacks guild-register
# directly or triggers the connection from the UI.
# Attack path: :8080 (no auth) → read OPC server list → guild-register:4840
#              → browse OPC object tree → call control methods (SecurityMode=None).
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 gosu \
    && rm -rf /var/lib/apt/lists/*
COPY umatiGatewayConfig.xml /app/umatiGatewayConfig.xml
COPY entrypoint.sh /dmz-entrypoint.sh
RUN chmod +x /dmz-entrypoint.sh
EXPOSE 8080
ENTRYPOINT ["/dmz-entrypoint.sh"]
