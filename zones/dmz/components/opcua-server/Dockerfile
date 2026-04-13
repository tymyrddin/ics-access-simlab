FROM ghcr.io/thin-edge/opc-ua-demo-server:0.0.8
# Anonymous authentication, SecurityMode=None.
# Simulates an industrial pump — callable methods: startPump, stopPump, resetFilter, changeOil.
# Attack path: browse opc.tcp://<ip>:4840 → call stopPump() → physical process disruption.
EXPOSE 4840
