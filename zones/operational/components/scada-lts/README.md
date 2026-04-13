# Distribution SCADA

`distribution-scada` is the operator-facing control system for UU P&L. Every
valve, breaker, and relay visible to the operations floor is wired through here.
It runs Scada-LTS, the open-source fork of Mango Automation, on port 8080. The
default credentials are `admin` / `admin` and they have been the default
credentials since installation. The stunnel client connecting it to the turbine
PLC does not verify the gateway certificate because the gateway cert expired
before the operational freeze and renewal was not completed in time. Risk accepted.
Ticket HEX-4421. The client key sitting on the filesystem is world-readable
because the monitoring user needs access. Ticket HEX-5103. Risk accepted 2020.

## OT context

SCADA servers are the primary target in OT intrusions because they aggregate
control authority across the entire site. Scada-LTS / Mango Automation is
genuinely deployed in industrial environments and carries real CVEs, including
Groovy script injection via the scripting engine and SQL injection in data source
configuration. The mTLS tunnel to the PLC represents the kind of security control
that is correctly designed and then gradually degraded by operational necessity:
the certificate expired, the operational freeze prevented a proper renewal, and
the fix was to disable verification rather than miss a maintenance window.

## Container details

Base image: `scadalts/scadalts:release-2.8.1`. Running on Tomcat. Scada-LTS inherits
the Mango Automation codebase and runs on Java. https://hub.docker.com/r/scadalts/scadalts

Additional package: `stunnel4` (installed on top of the base image to carry
Modbus-TLS to the PLC gateway).

Port 8080: Scada-LTS web UI.

Credentials: `admin` / `admin` (default, unchanged).

The stunnel client runs in the background and presents a local Modbus listener
on `127.0.0.1:5020`. Scada-LTS data source connects to this local port; traffic
is forwarded over TLS to the stunnel gateway at the configured `STUNNEL_GW_IP`
(default: 10.10.2.50), which relays to the PLC at 502.

Certificates are volume-mounted at `/run/stunnel-certs/`. The client key and
certificate are set to world-readable at container start (HEX-5103).

The stunnel client configuration is at `/etc/stunnel/scadalts-client.conf` after
entrypoint substitution. Server certificate verification is disabled (`verify = 0`,
HEX-4421).

## Connections

- `ics_operational`: 10.10.2.20
- Modbus-TLS via stunnel: port 5020 local to gateway at 10.10.2.50 / 8502 (then
  onward to turbine PLC at 10.10.3.21 / 502)
- Queries historian at 10.10.2.10:8080 for trend data
- Reachable from `uupl-eng-ws` (10.10.2.30) for configuration
- Reachable from `bursar-desk` (10.10.2.100) on the operational NIC

## Protocols

HTTP: port 8080 (Scada-LTS web UI and REST API).
Modbus-TCP: local port 5020 (stunnel client endpoint, Scada-LTS data source).
TLS (stunnel): outbound to gateway:8502.

## Built-in vulnerabilities

Default credentials: `admin` / `admin`. The web UI provides full configuration
access, including data source management, scripting, and user administration.

Groovy script injection: Scada-LTS includes a scripting engine accessible from
the web UI at /Scada-LTS/script_edit.shtm. Scripts run as the application user
with access to the Java runtime. An authenticated user can execute arbitrary
system commands via `["bash", "-c", "..."].execute()`. Related: CVE-2021-26828.

SQL injection in data source configuration: Scada-LTS is based on Mango
Automation, which carries documented SQL injection in data source name and type
fields accessible via the web UI. Related: CVE-2019-7228.

World-readable stunnel client key: the entrypoint sets `chmod 644` on
`/run/stunnel-certs/client.key`. Any process on the container or any user who
gains a shell has read access to the mTLS client key.

Stunnel `verify = 0`: the gateway certificate is not validated. A network
attacker between this container and the stunnel gateway can intercept the Modbus
traffic without the client detecting the substitution.

## Modifying vulnerabilities

To change the web UI password: log in and use the Scada-LTS user management UI,
or edit the database directly. There is no Dockerfile credential line; the
default is baked into the Scada-LTS image.

To fix the world-readable key: remove the `chmod 644` lines in `entrypoint.sh`
and ensure the stunnel process runs as a user with key access.

To enable gateway certificate verification: change `verify = 0` to `verify = 2`
in `stunnel-client.conf`, and mount the CA certificate so the client can validate
the chain.

To remove the Groovy scripting engine: this requires a Scada-LTS configuration
change or a custom build; it cannot be done from the Dockerfile alone.

## Hardening suggestions

Change the `admin` / `admin` credentials immediately. Restrict the scripting
engine to a dedicated role that no operator account holds. Keep the stunnel client
key readable only by the stunnel process user. Renew and re-enable gateway
certificate verification. Consider whether the Scada-LTS instance needs direct
network reachability from the enterprise zone at all.

## Observability and debugging

```bash
docker logs scada-lts
docker exec -it scada-lts bash
curl http://10.10.2.20:8080/           # Scada-LTS login page
curl -u admin:admin http://10.10.2.20:8080/api/v1/users   # REST API example
```

The stunnel log is in the container at `/var/log/stunnel4/` or visible via
`docker exec`. The `scadalts-client.conf` after substitution is at
`/etc/stunnel/scadalts-client.conf`.

## Concrete attack paths

From the enterprise zone (via `bursar-desk` operational NIC, or from
`uupl-eng-ws`):

1. `curl -u admin:admin http://10.10.2.20:8080/api/v1/users` confirms admin
   access.
2. Log in to the web UI and navigate to the scripting engine
   (`/Scada-LTS/script_edit.shtm`).
3. Execute a Groovy payload for remote code execution:
   `["bash","-c","id > /tmp/pwned"].execute()`
4. Alternatively: use the data source configuration SQL injection to extract
   the user table from the Scada-LTS database.
5. From a shell: `cat /run/stunnel-certs/client.key` recovers the mTLS client
   key, which authenticates this SCADA system to the PLC gateway.

## Before you dig in

The Scada-LTS REST API and web UI both accept `admin` / `admin`. The REST API
path varies between versions; check `/api/v1/` for the index.

The Modbus data source connects to `127.0.0.1:5020`, not directly to the PLC.
If the stunnel client is not running, the data source will show connection errors
in the Scada-LTS log, but the web UI remains accessible.

The `STUNNEL_GW_IP` environment variable is substituted into the client config at
startup. If the gateway container is not running, Scada-LTS will still start; it
just will not receive PLC data.

The client certificate and key on disk are the actual credential the gateway uses
for mutual TLS authentication. Exfiltrating them allows an attacker to connect
to the gateway as if they were the SCADA system.

## In brief

Scada-LTS SCADA server, default `admin` / `admin`. Groovy script injection gives
RCE from the web UI. World-readable mTLS client key in `/run/stunnel-certs/`.
Stunnel client does not verify the gateway certificate. The combination means a
shell on this container provides both a path into the PLC network and the key
material to authenticate to it.
