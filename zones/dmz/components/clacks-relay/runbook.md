# Runbook: clacks-relay

## Discovery

A sweep of the DMZ from contractors-gate turns up port 1883 on 10.10.5.12.

```bash
root@contractors-gate:~# nc -zv 10.10.5.12 1883
```

The TCP handshake completes. Port 1883 is the default MQTT broker port. A wildcard subscription reveals what is flowing through it.

## Observing live traffic

```bash
root@contractors-gate:~# mosquitto_sub -h 10.10.5.12 -t '#' -v
```

The broker is quiet until guild-exchange establishes its OPC-UA connection to guild-register. If topics are silent after a minute, guild-exchange may not yet have completed its startup.

## What arrives

Two publishers feed the broker in normal operation.

guild-exchange publishes pump telemetry from guild-register every five to ten seconds:

```
umati/v2/<namespace>/<node-name>    every 5 seconds
umati/v3/<namespace>/<node-name>    every 10 seconds
```

The namespace segment comes from the OPC-UA namespace URL `http://www.cumulocity.com`. The three node names are the OPC-UA display names for the Pump01 object on guild-register:

| Topic suffix         | OPC node ID | Meaning              | Unit |
|----------------------|-------------|----------------------|------|
| `.../operatingLevel` | 7           | pump operating level | %    |
| `.../flow`           | 9           | volumetric flow rate | m³/h |
| `.../power`          | 11          | power draw           | kW   |

When `stopPump` is called on guild-register, all three values change within one publish interval.

sorting-office publishes Modbus register data northbound under its own prefix once a southbound device is configured:

```
neuron/<sorting-office>/<group>/<tag>
```

No southbound device is wired by default, so the Neuron topics are absent until one is added.

## Injecting messages

The broker accepts publish from any anonymous client with no topic restrictions.

```bash
root@contractors-gate:~# mosquitto_pub -h 10.10.5.12 -t 'umati/v2/fake/flow' \
    -m '{"Value":0,"SourceTimestamp":"2024-01-01T00:00:00Z"}'
```

The broker does not retain messages. An injected value reaches a subscriber only during the injection window. Subscribing before the legitimate publisher fires is the more reliable approach.

## What you can know now

Access:
- MQTT at `10.10.5.12:1883`: anonymous publish and subscribe, all topics visible, no ACLs, no TLS

Data in flight:
- guild-exchange: `umati/v2/...` and `umati/v3/...` (pump telemetry, continuous once guild-exchange is up)
- sorting-office: `neuron/.../...` (Modbus readings, only after a southbound device is added)

## Quick reference

```
root@contractors-gate:~# nc -zv 10.10.5.12 1883                               confirm broker port
root@contractors-gate:~# mosquitto_sub -h 10.10.5.12 -t '#' -v               subscribe all topics
root@contractors-gate:~# mosquitto_sub -h 10.10.5.12 -t 'umati/#' -v         subscribe pump telemetry only
root@contractors-gate:~# mosquitto_pub -h 10.10.5.12 -t '<topic>' -m '<msg>' publish to any topic
```
