# IEC-104 RTU

`substation-rtu` is a custom Python service that exposes an IEC-60870-5-104
protocol endpoint and a REST management API. Both interfaces share the same
in-memory datapoint table, so a `POST` to the REST API mutates a value that
any IEC-104 master polling port 2404 will see on the next periodic report.

## Real substation context

Substation RTUs communicate over IEC-104 to SCADA systems and control centres.
The protocol itself has no authentication: access control is by network
isolation. An RTU management API with no authentication bypasses even that:
the attacker does not need to speak IEC-104 at all. Falsifying RTU datapoint
values via the REST API is equivalent to forging sensor readings, which in a
real substation would cause protection relays and automated control systems
to respond to conditions that do not exist. Vendor management UIs alongside
protocol ports are a real OT pattern: engineers commission via the web during
install, then forget to firewall.

## Container details

Base image: `python:3.11-slim-bookworm`. The IEC-104 server is provided by the
[c104](https://pypi.org/project/c104/) library (a Python wrapper around
[lib60870](https://github.com/mz-automation/lib60870)). The REST API is a
small Flask app. Both run in the same process and share the datapoint state
under a threading lock.

Earlier versions of this component used the upstream
`ghcr.io/richyp7/iec60870-5-104-simulator:v0.1.7` image, but that image has
no usable REST API: port 8080 is an empty Kestrel host. The runbook's
REST-mutation attack path required a custom build.

Source files in this directory:
- `rtu_server.py`: the service. ~150 lines.
- `rtu_config.json`: initial datapoint values.
- `Dockerfile`: pulls a manylinux wheel for `c104`, no native build needed.

Exposed ports:
- 2404/tcp: IEC-60870-5-104 protocol endpoint
- 8080/tcp: REST management API (no authentication)

## Datapoints

Live UUPL substation values representing the Dolly Sisters and Nap Hill
feeder segment, common address 20. Values are updated every ten seconds by
`rtu_updater.py` running on `uupl-eng-ws`:

| Id | Name | TypeId | Source | Description |
|---|---|---|---|---|
| 1 | feeder_a_voltage | M_ME_NC_1 (13) | PLC IR[3] × 0.05 | Feeder A voltage, kV |
| 2 | feeder_b_voltage | M_ME_NC_1 (13) | PLC IR[5] × 0.05 | Feeder B voltage, kV |
| 3 | load_current     | M_ME_NC_1 (13) | PLC IR[4] | Load current, A |
| 4 | frequency        | M_ME_NC_1 (13) | PLC IR[7] ÷ 10 | Grid frequency, Hz |
| 5 | breaker_a_state  | M_SP_NA_1 (1)  | relay-a COIL[0] inverted | Feeder A breaker: true=closed |
| 6 | breaker_b_state  | M_SP_NA_1 (1)  | relay-b COIL[0] inverted | Feeder B breaker: true=closed |

The voltage scaling maps the LV bus (220 V nominal) through the step-up
transformer to the 11 kV distribution feeder. Breaker state is the logical
inverse of the relay trip coil: COIL[0]=1 (tripped) appears here as false
(open).

The correlation matters for the attack: setting feeder voltage to 0 while the
breaker state stays true creates an operationally impossible reading. With live
values flowing in every ten seconds, injected values get overwritten within one
polling cycle.

## Connections

- `ics_dmz`: 10.10.5.14
- Reachable from `ics_internet` and from within `ics_dmz`
- `uupl-eng-ws` (10.10.2.30) pushes live values via the REST API every 10 s
- An IEC-104 master can subscribe to spontaneous data from port 2404

## REST API

| Method | Path | Body | Effect |
|---|---|---|---|
| GET | `/` | | Service info and route list |
| GET | `/datapoints` | | List all datapoints with current values |
| GET | `/datapoints/<id>` | | Read one datapoint |
| POST | `/datapoints/<id>` | `{"value": ...}` | Update value, push spontaneous IEC-104 update |

The POST endpoint normalises the incoming value to the datapoint's declared
type: floats for measured values (TypeId 13), booleans for single-point
information (TypeId 1).

## Built-in vulnerabilities

Unauthenticated REST API: the management API on port 8080 accepts all
requests without credentials. POST to a datapoint to set its value; any
IEC-104 master polling port 2404 sees the injected value within one
periodic report cycle, and an explicit spontaneous transmission is also
fired so connected masters get the new value immediately.

IEC-104 has no authentication: any IEC-104 client that reaches port 2404 can
send commands. The simulator responds as a real RTU would.

## Hardening suggestions

Restrict port 8080 to operator workstation IPs (firewall or per-route
allow-list in Flask). Place an authenticating reverse proxy in front of the
management API. Apply IEC-104 network isolation so that only the legitimate
SCADA master can reach port 2404.

## Observability and debugging

```bash
docker logs substation-rtu
curl http://10.10.5.14:8080/                # service index
curl http://10.10.5.14:8080/datapoints      # all values
```

## Concrete attack paths

From the internet zone or from within the DMZ:

1. `curl http://10.10.5.14:8080/datapoints` lists all six datapoints with
   their current values, types, units, and IDs.
2. Falsify a reading while leaving the corresponding correlated value intact:
   set feeder voltage to 0 while the breaker state stays true. The
   inconsistency looks like a sensor fault or relay misoperation to an
   operator.
3. `curl -X POST http://10.10.5.14:8080/datapoints/4 -d '{"value": 47.2}'`
   pushes an under-frequency reading; the RTU spontaneously transmits the
   new value to any connected IEC-104 master.
4. If a SCADA system or control centre polls this RTU, it receives the
   injected reading and may act on it (protection relay response, alarm,
   automated switch action).

From a native IEC-104 client (e.g. lib60870-python, c104 client mode, or
similar): connect to 10.10.5.14:2404, send `STARTDT_ACT`, and the RTU will
begin sending periodic and spontaneous data. Send single-command ASDUs to
operate simulated field devices.

## Edge cases

The REST API serves stable JSON since the service is built in-house. Field
names match `rtu_config.json` exactly.

IEC-104 requires a STARTDT (start data transfer) handshake before the RTU
begins sending data. Most IEC-104 client libraries handle this automatically;
raw TCP connections need to send the correct U-frame.

Injected values via the REST API take effect immediately on the IEC-104
endpoint, with both an internal state update and a spontaneous transmission.

## Summary

Custom Python IEC-60870-5-104 RTU built on `c104` plus Flask. IEC-104 on port
2404 (no auth), REST API on port 8080 (no auth). POST a value to any
datapoint via the REST API and any IEC-104 master polling the RTU will see
the falsified reading on the next cycle (or immediately, via the spontaneous
transmit the REST handler fires).
