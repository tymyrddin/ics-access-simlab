# DMZ MQTT broker

`clacks-relay` is the MQTT broker for the DMZ. It acts as the northbound message
bus between industrial protocol gateways in the DMZ and any consumer that
subscribes. `allow_anonymous true` means no credentials are required to publish
or subscribe. The name is a reference: the Clacks is the Discworld's semaphore
tower network, which also transmits messages without asking who you are.

## MQTT brokers in real OT

MQTT brokers in IIoT DMZ deployments serve as the aggregation point for telemetry
from multiple protocol gateways before it is forwarded to a cloud platform or
analytics layer. Anonymous access is a common deployment oversight, particularly
in test and staging environments that become permanent. An unauthenticated broker
in the DMZ is an information disclosure point and a potential injection vector
into downstream systems that trust the broker's data.

## Container details

Base image: `eclipse-mosquitto:2.0.22`.

Exposed port: 1883/tcp (MQTT, no TLS, no authentication).

Configuration: `allow_anonymous true`, `persistence false`.

Two publishers in normal operation:
- guild-exchange (10.10.5.10): OPC-UA pump telemetry under `umati/v2/...` and
  `umati/v3/...`, every 5-10 seconds. Starts automatically once guild-exchange
  establishes its OPC-UA connection to guild-register. The .NET Kestrel startup
  can take 2-3 minutes; the broker is quiet until it connects.
- sorting-office (10.10.5.11): Modbus register data under `neuron/sorting-office/...`.
  The northbound MQTT node is pre-configured, but no southbound device is wired
  by default. Topics appear only after a southbound device is added via the API.

## Connections

- `ics_dmz`: 10.10.5.12
- Published to by other DMZ components when configured

## Protocols

MQTT 3.1.1: port 1883. No TLS. No authentication.

## Built-in vulnerabilities

Anonymous access: any host on the DMZ can publish or subscribe without
credentials.

Plaintext: MQTT traffic is not encrypted. Any host that can receive traffic on
`ics_dmz` can intercept the message stream.

Message injection: a host that can reach port 1883 can publish to any topic,
including topics that downstream consumers (analytics platforms, operator
dashboards) treat as authoritative plant data.

## Modifying vulnerabilities

To require authentication: add a password file and set `password_file` and
`allow_anonymous false` in `mosquitto.conf`. Create the password file with
`mosquitto_passwd`.

To add TLS: mount a certificate and key and add `cafile`, `certfile`,
`keyfile` directives. Change the listener port to 8883 if TLS is preferred on a
separate port.

## Hardening suggestions

Enable authentication. Add TLS. Define an ACL that restricts publishers to their
own topics and limits subscriptions to legitimate consumers.

## Observability and debugging

```bash
docker logs clacks-relay
docker exec clacks-relay mosquitto_sub -h 127.0.0.1 -t '#' -v   # subscribe inside broker container
mosquitto_sub -h 10.10.5.12 -t '#' -v                           # subscribe from any host with network access
```

## Concrete attack paths

From the internet zone:

1. `mosquitto_sub -h 10.10.5.12 -t '#' -v` subscribes to all topics. Any data
   published by Neuron or umatiGateway will appear here.
2. `mosquitto_pub -h 10.10.5.12 -t 'uupl/turbine/telemetry' -m '{"rpm":3000}'`
   injects a message on any topic. If a downstream consumer subscribes to this
   topic, it receives the injected data.

## Caveats

The broker does not persist messages. A subscriber that connects after a message
was published misses it. For telemetry injection to be effective, the injection
rate needs to exceed the legitimate publisher's rate or the subscriber needs to
be redirected to trust injected messages.

The DMZ MQTT broker (`clacks-relay`) is separate from the control-zone broker
(`uupl-mqtt` at 10.10.3.60). They do not bridge to each other by default.

## At a glance

Mosquitto MQTT broker in the DMZ, `allow_anonymous true`. Any host reachable
from `ics_dmz` can subscribe to all telemetry and publish arbitrary messages.
No TLS, no authentication, no ACL.
