FROM ghcr.io/thin-edge/opc-ua-demo-server:0.0.8
# Anonymous authentication, SecurityMode=None.
# Simulates an industrial pump — callable methods: startPump, stopPump, resetFilter, changeOil.
# Attack path: browse opc.tcp://<ip>:4840 → call stopPump() → physical process disruption.
USER root
RUN apt-get update \
    && apt-get install -y --no-install-recommends iproute2 gosu \
    && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh /dmz-entrypoint.sh
RUN chmod +x /dmz-entrypoint.sh
EXPOSE 4840
ENTRYPOINT ["/dmz-entrypoint.sh"]
