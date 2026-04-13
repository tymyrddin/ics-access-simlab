# IEC-104 RTU

`substation-rtu` runs an IEC-60870-5-104 simulator. It exposes the standard
IEC-104 protocol endpoint on port 2404 and a REST API on port 8080 with no
authentication. The REST API allows any caller to reconfigure datapoints and
set their values on the fly. An operator misconfigured to trust this RTU's
readings will act on whatever values an attacker sets via the API.

## Real substation context

Substation RTUs communicate over IEC-104 to SCADA systems and control centres.
In real deployments, IEC-104 itself has no inherent authentication mechanism;
access control is by network isolation. An RTU management API with no
authentication bypasses even that: the attacker does not need to speak IEC-104
at all. Falsifying RTU datapoint values via the REST API is equivalent to forging
sensor readings, which in a real substation would cause protection relays and
automated control systems to respond to conditions that do not exist.

## Container details

Base image: `ghcr.io/richyp7/iec60870-5-104-simulator:v0.1.7`. https://github.com/RichyP7/IEC60870-5-104-simulator

Exposed ports:
- 2404/tcp: IEC-60870-5-104 protocol endpoint
- 8080/tcp: REST management API (no authentication)

The simulator starts with a default set of datapoints. These can be queried,
modified, and extended via the REST API at any time.

## Connections

- `ics_dmz`: 10.10.5.14
- Reachable from `ics_internet` and from within `ics_dmz`
- An IEC-104 master (SCADA or control centre) can subscribe to spontaneous data from port 2404

## Protocols

- IEC-60870-5-104: port 2404.
- HTTP: port 8080 (REST management API, no authentication).

## Built-in vulnerabilities

Unauthenticated REST API: the management API on port 8080 accepts all requests
without credentials. Documented attack path: `POST` to the datapoint API to
set arbitrary values. Any IEC-104 master polling this RTU will receive the
injected values as if they were real measurements.

IEC-104 has no authentication: any IEC-104 client that reaches port 2404 can
send commands (ASDU type C_SC_NA_1 for single commands, C_DC_NA_1 for double
commands). The simulator responds to these as a real RTU would.

## Modifying vulnerabilities

To add authentication to the REST API: the upstream image does not support API
authentication in v0.1.7; this requires either a custom image wrapping the
simulator with an authenticating reverse proxy or a newer image version if
authentication was added upstream.

To change which datapoints are configured: use the REST API while the container
is running, or inspect the upstream repository for a configuration file format
that can be volume-mounted.

## Hardening suggestions

Place an authenticating reverse proxy in front of the management API. Restrict
port 8080 to specific operator workstation IPs. Apply IEC-104 network isolation
so that only the legitimate SCADA master can reach port 2404.

## Observability and debugging

```bash
docker logs iec104-rtu
curl http://10.10.5.14:8080/             # API index / datapoint list
```

Typical REST API paths (consult upstream documentation for the exact schema):
```bash
curl http://10.10.5.14:8080/datapoints   # list all datapoints
curl -X POST http://10.10.5.14:8080/datapoints/1 \
  -H 'Content-Type: application/json' \
  -d '{"value": 9999}'                   # set a datapoint value
```

## Concrete attack paths

From the internet zone or from within the DMZ:

1. `curl http://10.10.5.14:8080/datapoints` lists all datapoints with their
   current values and types.
2. Identify a measurement datapoint (e.g. line voltage or current).
3. `POST` a falsified value: the RTU will now report this value to any IEC-104
   master that polls it.
4. If a SCADA system or control centre polls this RTU, it receives the injected
   reading and may act on it (protection relay response, alarm, automated switch
   action).

From a native IEC-104 client (e.g. lib60870-python or similar):
- Connect to 10.10.5.14:2404, send `STARTDT_ACT`, and the RTU will begin
  sending spontaneous data. Send single-command ASDUs to operate simulated
  field devices.

## Edge cases

The REST API path structure varies between versions of the simulator. Use
`curl http://10.10.5.14:8080/` to discover the available routes.

IEC-104 requires a STARTDT (start data transfer) handshake before the RTU sends
spontaneous data. Most IEC-104 client libraries handle this automatically; raw
TCP connections need to send the correct U-frame.

Injected values via the REST API take effect immediately on the IEC-104 endpoint.
There is no batching or delay.

## Summary

IEC-60870-5-104 RTU simulator. IEC-104 on port 2404 (no auth). REST management
API on port 8080 (no auth). POST a value to any datapoint via the REST API and
any IEC-104 master polling the RTU will receive the falsified reading.
