FROM ghcr.io/thin-edge/opc-ua-demo-server:0.0.8
# OPC-UA sidecar for hex-turbine-plc (10.10.3.21).
# Shares the PLC's network namespace: reachable on opc.tcp://10.10.3.21:4840.
# Same image as guild-register in the DMZ; different IP, different zone, different
# attack context — here the attacker has already broken into the control network.
# SecurityMode=None, anonymous authentication. No credentials required.
# Attack path: browse node tree → call control methods (e.g. stopPump) → disrupt process.
EXPOSE 4840
