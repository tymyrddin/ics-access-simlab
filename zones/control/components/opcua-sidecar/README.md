# OPC-UA sidecar

`turbine_opcua` is a sidecar container that adds an OPC-UA endpoint to
`hex-turbine-plc` (10.10.3.21). It shares the PLC's network namespace, so
the endpoint appears on the same IP: `opc.tcp://10.10.3.21:4840`.

This reflects a common pattern in real generation plant: a PLC that was
commissioned with Modbus and IEC-104 receives an OPC-UA integration later,
often bolted on as a separate process rather than rewritten into the existing
firmware. The result is several protocol interfaces on one IP, each added by
a different team at a different time.

## Container details

Base image: `ghcr.io/thin-edge/opc-ua-demo-server:0.0.8`. Same image as
`guild-register` in the DMZ; the attack context is different. Here the attacker
has already broken into the control network and is working at the PLC layer.

Network: shares `turbine_plc` network namespace via `network_mode: service:turbine-plc`.
IP: 10.10.3.21 (same as PLC). Port: 4840/tcp.

SecurityMode: None. Authentication: anonymous. No credentials required.

The sidecar starts after `turbine_plc` (`depends_on`).

## Connections

- `ics_control`: 10.10.3.21:4840 (inherited from parent)
- Not directly reachable from `ics_enterprise` or `ics_dmz`: control zone firewall applies

## Protocols

OPC-UA: port 4840. SecurityMode None, anonymous auth.

## Built-in vulnerabilities

No authentication and no transport security. Any OPC-UA client that reaches
port 4840 can browse the node tree, read values, and call methods. The node
tree is the thin-edge industrial device demo (pump-like objects with callable
methods including `stopPump`). Calling a stop method on a device that a SCADA
system believes is a running turbine component creates a false process state.

The endpoint is reachable only from inside the control zone or from a host
that has pivoted there. That is the point: once inside, the attacker finds
an unauthenticated OPC-UA interface sitting on the same address as a PLC they
may already be accessing via Modbus.

## Hardening suggestions

Add OPC-UA security: at minimum, require `Sign` or `SignAndEncrypt` transport
security and certificate-based authentication. Restrict port 4840 to specific
OPC-UA clients (the SCADA system and engineering workstation). Audit which
OPC-UA methods are callable and whether any have physical consequences.

## Observability and debugging

```bash
docker logs turbine_opcua
# OPC-UA client connection (e.g. using opcua-client-gui or python-opcua):
# endpoint: opc.tcp://10.10.3.21:4840
# security: None
# authentication: anonymous
```

## Concrete attack path

After gaining a foothold in the control zone (e.g. via the engineering
workstation at 10.10.3.100):

1. Port-scan 10.10.3.21: port 4840 appears alongside 502 and 2404.
2. Connect with any OPC-UA client: anonymous, SecurityMode None.
3. Browse the node tree to discover available objects and methods.
4. Call `stopPump` or equivalent: the SCADA system at `uupl-hmi` will show
   an unexpected state change on the next polling cycle.

## In brief

OPC-UA sidecar on hex-turbine-plc. `opc.tcp://10.10.3.21:4840`, no auth,
SecurityMode None. Reachable from inside the control zone after pivoting in.
