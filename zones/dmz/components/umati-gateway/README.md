# umatiGateway

`guild-exchange` runs umatiGateway, a .NET 8 application that bridges OPC-UA
servers to MQTT brokers. The web management UI on port 8080 requires no
authentication. An operator can add, remove, or modify OPC-UA server connections
and MQTT routing rules from a browser without providing any credentials. This is
CVE-2025-27615.

The image is `ghcr.io/umati/umatigateway:pr-375`, a pre-fix pull-request build.

## In real IIoT deployments

OPC-UA-to-MQTT gateways are increasingly common in IIoT architectures: they
translate proprietary industrial protocol data into a format cloud platforms and
analytics dashboards can consume. A gateway with an unauthenticated management
interface is a significant lateral movement and data manipulation point: it can
be reconfigured to point at internal OPC-UA servers, read confidential process
data, or inject false values into the MQTT stream that downstream consumers treat
as authoritative.

## Container details

Base image: `ghcr.io/umati/umatigateway:pr-375`. .NET 8 runtime. https://github.com/umati/umatiGateway

Documentation: https://deepwiki.com/umati/umatiGateway/5.1-docker-deployment

Exposed port: 8080/tcp (web management UI, no authentication).

The gateway is not pre-configured with any OPC-UA connections in this scenario.
Connections are added and managed via the web UI. Any OPC-UA server reachable
from the DMZ can be added.

## Connections

- `ics_dmz`: 10.10.5.10
- Reachable from `ics_internet` (10.10.0.0/24) and from `ics_dmz`
- Can reach OPC-UA servers within the DMZ (e.g. guild-register at 10.10.5.13)

## Protocols

HTTP: port 8080 (management UI, CVE-2025-27615, no authentication).
OPC-UA: outbound client connections (configured via the UI).
MQTT: outbound publisher connections (configured via the UI).

## Built-in vulnerabilities

Unauthenticated management UI (CVE-2025-27615): the web interface on port 8080
accepts all configuration requests without authentication. An attacker can add
OPC-UA server connections, configure MQTT output, and read the gateway's current
configuration.

Reconnaissance via UI: the connections page lists all configured OPC-UA servers
with their endpoints, security modes, and browsed node trees. This reveals the
internal address topology of any servers the gateway is connected to.

Data injection: by adding a connection to the DMZ MQTT broker
(`clacks-relay`, 10.10.5.12) and publishing arbitrary node values, an attacker
can inject data into any downstream consumer that reads from the broker.

## Modifying vulnerabilities

The authentication fix is in the upstream codebase beyond the `pr-375` tag.
To use the patched version, replace the image tag with the post-fix release.

To add pre-configured connections: the gateway stores its configuration in a
volume or in-container state; connections can be seeded at build time if the
upstream image supports a config file at a known path.

## Hardening suggestions

Use a post-CVE-2025-27615 image. Add authentication to the management UI. Restrict
network access to port 8080 to the specific operator workstations that need it.
Define an allowlist of permitted OPC-UA server endpoints and refuse connections
to addresses outside that list.

## Observability and debugging

```bash
docker logs umati-gateway
curl http://10.10.5.10:8080/            # management UI
```

The UI provides a live view of configured connections and their status.

## Concrete attack paths

From the internet zone (`unseen-gate` at 10.10.0.5, which has internet→dmz
firewall access):

1. `curl http://10.10.5.10:8080/` confirms the UI is accessible.
2. Browse the management UI and add an OPC-UA connection to `guild-register`
   (10.10.5.13:4840), the thin-edge OPC-UA demo server.
3. Read all browsable nodes: confirm pump state, call methods (`stopPump`) via
   the gateway's method-call UI if available.
4. Add an MQTT output connection to `clacks-relay` (10.10.5.12:1883) and
   configure the gateway to publish OPC-UA node values to a chosen topic.

## Known oddities

The pr-375 image is a pre-merge build and may have startup quirks not present in
a release image. If the container exits at start, check `docker logs` for .NET
runtime errors.

The gateway requires network reachability to any OPC-UA server it is configured
to connect to. Within the DMZ, this is unrestricted. Connections to the
operational or control zones are blocked by the firewall.

## In brief

umatiGateway, pre-fix. Web management UI on port 8080, no authentication
(CVE-2025-27615). Can be configured to connect to any reachable OPC-UA server
and publish its data to MQTT. Reconnaissance, lateral movement, and data
injection, all from a browser.
