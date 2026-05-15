# Neuron gateway

`sorting-office` runs Neuron (emqx/neuron), an industrial protocol gateway that
converts Modbus, OPC-UA, IEC-104, and other southbound protocols into MQTT
northbound messages. The management API on port 7000 accepts `admin` / `uupl2015`.

The password has been changed from the factory default (`admin` / `0000`) to
`uupl2015`. This is the same password as the `root` account on `contractors-gate`.
The reuse is deliberate and discoverable: an attacker who finds either credential
can try it on the other service.

A northbound MQTT output to `clacks-relay` (10.10.5.12:1883) is pre-configured.
There is no southbound device. The attacker can add that, after gaining a foothold
inside the network from which the control zone is reachable.

## Protocol gateways in real OT

Industrial protocol gateways are the translation layer between legacy fieldbus
and modern data platforms. They are increasingly deployed at the IT/OT boundary
or in a DMZ to avoid exposing PLCs directly to the internet. A gateway with
default credentials is more dangerous than a directly-exposed PLC in some
respects: it provides both data access and write capability to any device it
has been configured to reach, and the interface is a well-documented REST API
rather than raw Modbus.

## Container details

Base image: `emqx/neuron:2.11.5`.

Exposed port: 7000/tcp (management web UI and REST API).

Credentials: `admin` / `uupl2015`. Changed from factory default at build time.
The Neuron dashboard and the REST API share these credentials.

Pre-configured northbound: MQTT output node `uupl-mqtt-north` targeting
`clacks-relay` (10.10.5.12:1883). Topics: `/neuron/sorting-office/write/req`
and `/neuron/sorting-office/write/resp`. The node is created and configured
at image build time via the Neuron REST API; the state persists in SQLite.

Neuron supports multiple southbound driver plugins including Modbus TCP, OPC-UA,
IEC-104, and DNP3. Northbound outputs include MQTT and SparkplugB.

## Connections

- `ics_dmz`: 10.10.5.11
- Can connect outbound to Modbus devices reachable from the DMZ
- Can publish northbound to the DMZ MQTT broker (`clacks-relay`, 10.10.5.12)

## Protocols

HTTP: port 7000 (Neuron management UI and REST API).
Modbus TCP: outbound, configured via the management UI.
MQTT: outbound, configured northbound output plugin.

## Built-in vulnerabilities

Reused credential: `admin` / `uupl2015`. The same password is on the
ssh-bastion root account (`contractors-gate`). An attacker who finds one
credential can try it on the other.

Southbound device configuration: once authenticated, an attacker can add a new
Modbus TCP device pointing at any host reachable from sorting-office. The control
zone is not directly reachable from the DMZ by firewall rules. The intended
attack path requires a prior inner-network foothold (e.g. on the engineering
workstation at 10.10.2.30 or the stunnel gateway at 10.10.3.50), from which
the turbine PLC (10.10.3.21:502) is reachable. Once a southbound Modbus device
is configured in Neuron and PLC registers are being polled, the northbound MQTT
output to clacks-relay exfils the data back out through the DMZ.

This teaches why default-credential gateways in the DMZ are dangerous even when
firewalled from the control zone: once an attacker is inside, the gateway becomes
a persistent exfil pipeline.

No TLS on the management API.

## Modifying vulnerabilities

To change the admin password: use the REST API at build time or log in via the
management UI and change it there. The build-time bootstrap uses
`POST /api/v2/password` with `{"name":"admin","old_pass":"...","new_pass":"..."}`.

To add a southbound device at build time: extend the bootstrap section of the
Dockerfile to add a node with `POST /api/v2/node` and configure it with
`POST /api/v2/node/setting` before the bootstrap shuts down.

To disable the management API: this requires a custom Neuron build or a reverse
proxy that blocks unauthenticated requests.

## Hardening suggestions

Change the default `admin` / `0000` credentials immediately. Enable HTTPS on
the management API. Define an explicit allowlist of southbound targets and refuse
connections outside that range. Restrict network access to port 7000 to specific
operator workstations.

## Observability and debugging

```bash
docker logs neuron-gateway
curl http://10.10.5.11:7000/   # management UI
```

REST API authentication:
```bash
curl -X POST http://10.10.5.11:7000/api/v2/login \
  -H 'Content-Type: application/json' \
  -d '{"name":"admin","pass":"uupl2015"}'
```

## Concrete attack path

This is a multi-stage chain that requires a prior inner-network foothold.

1. Gain a shell on `uupl-eng-ws` (10.10.2.30) or reach `uupl-modbus-gw`
   (10.10.3.50) via Phase 1. The turbine PLC at 10.10.3.21:502 is reachable
   from both.
2. Authenticate to Neuron: `POST /api/v2/login` with `admin` / `uupl2015`.
3. Add a Modbus TCP south node pointing at the turbine PLC:
   `POST /api/v2/node` then configure the address and register map.
4. Neuron polls the PLC and forwards readings to the northbound MQTT node
   (`uupl-mqtt-north`), which publishes to `clacks-relay` (10.10.5.12:1883).
5. From the internet zone, subscribe to `clacks-relay` on port 1883 and read
   live PLC telemetry.

## Heads up

The control zone (10.10.3.0/24) is not reachable from the DMZ. The southbound
Modbus device only works after a foothold on a zone that can reach the control
network (operational or control zone). The northbound MQTT output is pre-configured
and requires no attacker action.

The Neuron management port is 7000, not 8080. The EXPOSE in the Dockerfile and
the firewall rules both reflect 7000.

## Bottom line

Neuron industrial protocol gateway, `admin` / `uupl2015` (reused from ssh-bastion).
REST API on port 7000. Northbound MQTT output to clacks-relay pre-configured.
No southbound device: add that after gaining a foothold from which the PLC is
reachable, and the gateway becomes a persistent exfil pipeline out through the DMZ.
