# Control SCADA

`uupl-hmi` (scada-lts-ctrl) is the Scada-LTS instance in the control zone,
at Purdue Level 2. It gives operators a view of the turbine process and the
ability to issue control commands to field devices via the Modbus-TLS gateway.
It is structurally identical to the operational-zone Scada-LTS instance but sits
one zone closer to the physical process.

Default credentials: `admin` / `admin`. The stunnel client key is world-readable.
The server certificate is not verified. These are the same conditions as the
operational-zone instance because the image and the build process are the same.

## In real generation sites

Many generation sites run two SCADA tiers: an operational (Level 3) instance
for historian queries and reporting, and a control (Level 2) instance for direct
operator interaction with field devices. In practice, both often end up with the
same credentials and the same security posture because they were deployed from
the same template.

## Container details

Base image: `scadalts/scadalts:release-2.8.1` with `stunnel4` added. https://hub.docker.com/r/scadalts/scadalts

Port 8080: Scada-LTS web UI.
Credentials: `admin` / `admin`.

Stunnel client gateway: `STUNNEL_GW_IP` defaults to `10.10.3.50`. The client
configuration is at `/etc/stunnel/scadalts-ctrl-client.conf` after entrypoint
substitution. Server certificate verification is disabled (`verify = 0`,
HEX-4421). Client key and certificate are world-readable (HEX-5103).

The Modbus data source in Scada-LTS connects to `127.0.0.1:5020`, which the
stunnel client forwards over TLS to the gateway.

## Connections

- `ics_control`: 10.10.3.10 (the control zone address listed in engineering notes)
- Modbus-TLS via stunnel: port 5020 local to gateway at 10.10.3.50 / 8502
- Reachable from engineering workstation (10.10.3.100) and from operational zone

## Protocols

HTTP: port 8080 (Scada-LTS web UI and REST API).
Modbus-TCP: local port 5020 (stunnel client endpoint).
TLS (stunnel): outbound to gateway:8502.

## Built-in vulnerabilities

Identical to the operational-zone scada-lts: default `admin` / `admin`
credentials, Groovy script injection via the scripting engine, SQL injection in
data source configuration, world-readable stunnel client key, and stunnel
`verify = 0`.

See `zones/operational/components/scada-lts/README.md` for full vulnerability
detail. The attack paths are the same; the network position is different
(control zone rather than operational zone).

## Modifying vulnerabilities

Identical to the operational-zone instance. See the scada-lts README.

## Hardening suggestions

Change `admin` / `admin`. Restrict the scripting engine. Fix the world-readable
key. Enable gateway certificate verification. Separate the control-zone SCADA
credentials from the operational-zone instance.

## Observability and debugging

```bash
docker logs scada-lts-ctrl
docker exec -it scada-lts-ctrl bash
curl http://10.10.3.10:8080/
```

## Concrete attack paths

From the control network or from the engineering workstation:

1. `curl -u admin:admin http://10.10.3.10:8080/api/v1/users` confirms admin
   access.
2. Groovy script injection via `/Scada-LTS/script_edit.shtm` for RCE.
3. `cat /run/stunnel-certs/client.key` recovers the mTLS client key for the
   control-zone stunnel gateway.

## Worth knowing

This instance's stunnel gateway target is 10.10.3.50, not 10.10.2.50 (the
operational-zone gateway). They are separate gateway instances for separate
network segments.

The engineering notes on the engineering workstation document this host as
`uupl-hmi` at 10.10.3.10 with credentials `operator / operator`. Those
credentials are for the legacy `hmi` component (see its README); this
Scada-LTS instance uses `admin / admin`.

## The short version

Control-zone Scada-LTS, Purdue Level 2. Same vulnerabilities as the
operational-zone instance: `admin` / `admin`, Groovy RCE, world-readable mTLS
client key. One zone closer to the physical process.
