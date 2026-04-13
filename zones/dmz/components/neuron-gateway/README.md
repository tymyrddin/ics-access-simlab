# Neuron gateway

`sorting-office` runs Neuron (emqx/neuron), an industrial protocol gateway that
converts Modbus, OPC-UA, IEC-104, and other southbound protocols into MQTT
northbound messages. The management API on port 7000 accepts `admin` / `0000`.
These are the factory defaults and they have not been changed.

The practical consequence: anyone who reaches port 7000 can add a new Modbus
south device pointing at the turbine PLC and begin reading or writing registers
via the Neuron API.

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

Default credentials: `admin` / `0000`. The Neuron dashboard and the REST API
share these credentials.

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

Default credentials: `admin` / `0000`. The management API is fully functional
with these credentials from any host that reaches port 7000.

Southbound device configuration: once authenticated, an attacker can add a new
Modbus TCP device with the turbine PLC's address (10.10.3.21:502) as the target.
The control zone is not directly reachable from the DMZ by firewall rules, but
the historian and SCADA web ports (8080) on the operational zone are explicitly
permitted. An attacker can configure a southbound connection to either permitted
destination and use Neuron as a Modbus proxy.

Northbound MQTT bridge: once a southbound device is configured, Neuron publishes
its readings to the configured MQTT broker. Subscribing to the broker reveals
whatever the southbound device returns.

No TLS on the management API.

## Modifying vulnerabilities

To change the admin password: log in via the management UI and use the user
management section. The password can also be set via the REST API:
`POST /api/v2/password` with the new credentials.

To pre-configure a southbound device: Neuron supports a JSON configuration import
if the config directory is volume-mounted and the file is present at startup.

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
  -d '{"name":"admin","pass":"0000"}'
```

## Concrete attack paths

From the internet zone or from within the DMZ:

1. `curl -X POST http://10.10.5.11:7000/api/v2/login -d '{"name":"admin","pass":"0000"}'`
   returns a JWT token.
2. Use the token to call `GET /api/v2/plugin` and list available southbound
   drivers.
3. Add a Modbus TCP node pointing at the historian's management address
   (10.10.2.10:8080 is permitted by firewall). If any Modbus port is reachable,
   configure reads and monitor via MQTT.
4. Add a northbound MQTT output to `clacks-relay` (10.10.5.12:1883) and
   subscribe to confirm data flow.

## Heads up

Neuron requires the southbound device to be reachable. The firewall permits DMZ
to historian (10.10.2.10:8080) and SCADA (10.10.2.20:8080) on port 8080 only.
Modbus (port 502) is not permitted from the DMZ to the operational zone; add the
southbound device with the correct permitted port.

The Neuron management port is 7000, not 8080. The EXPOSE in the Dockerfile and
the firewall rules both reflect 7000.

## Bottom line

Neuron industrial protocol gateway, `admin` / `0000` factory defaults. REST API
on port 7000 allows adding southbound Modbus/OPC-UA devices and northbound MQTT
output. An attacker who reaches port 7000 can use Neuron as a protocol proxy to
reach permitted operational-zone services.
