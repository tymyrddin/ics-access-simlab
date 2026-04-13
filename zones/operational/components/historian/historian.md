# Historian: HIST-SRV01

## Device description

The UU P&L Process Historian is the time-series store for the entire plant.
Every sensor reading, alarm event, and production metric flows through it. The
operations floor depends on it for shift reports. The SCADA dashboard queries it
every time someone loads the operator view. The engineering workstation pulls
exports from it on a cron job. It has been running continuously since 1997.

The historian predates any meaningful concept of OT security at UU P&L. It was
installed by a contractor who is no longer reachable. The database schema and
the credentials set at installation have not changed since.

The container presents as a Windows Server 2019 system. SSH on port 22 accepts
password authentication and drops the user into a PowerShell facade. The web
service runs on port 8080.

From an attacker's perspective, the historian is valuable for two reasons:

* it is the most information-rich system in the operational zone: asset names,
  trip thresholds, alarm setpoints, and operational notes are all in the database
* the SQL injection in the report endpoint gives direct read access to every
  table, including alarm configuration that reveals the exact values needed to
  cause a relay trip without triggering protection

The `/export` path traversal then gives unauthenticated read access to
arbitrary files on the filesystem, including the raw SQLite database.

## Container behaviour

The container exposes two network services:

* SSH on port 22: password authentication, Windows Server 2019 facade shell
* Flask web service on port 8080: no authentication on read endpoints

The web service endpoints:

| Endpoint  | Method | Auth           | Description                                     |
|-----------|--------|----------------|-------------------------------------------------|
| `/`       | GET    | none           | Version banner only                             |
| `/report` | GET    | none           | CSV time-series data, asset + date range params |
| `/assets` | GET    | none           | Lists all known asset names                     |
| `/export` | GET    | none           | Serves files from exports directory             |
| `/status` | GET    | none           | JSON health check, returns reading count        |
| `/ingest` | POST   | Basic (weak)   | Writes records directly to the readings table   |

The virtual Windows filesystem is mounted at `/opt/winsvr/C`. The SSH shell
presents this as `C:\`. PSReadLine history, configuration files, and operational
notes are all discoverable through normal directory browsing after SSH login.

## Deliberately introduced vulnerabilities

### SQL injection in /report

The asset parameter is interpolated directly into the SQL query string:

```python
query = (
    f"SELECT timestamp, value, unit FROM readings "
    f"WHERE asset = '{asset}' "
    f"AND timestamp BETWEEN '{from_date}' AND '{to_date}' "
    f"ORDER BY timestamp ASC"
)
rows = db.execute(query).fetchall()
```

The error message is returned verbatim on failure, which confirms successful
injection and discloses table and column names.

The database contains three tables of interest:

* `readings`: all time-series data
* `alarm_config`: trip thresholds for every monitored asset
* `config`: database credentials

A UNION injection against the `config` table returns the database password.
A UNION injection against the `alarm_config` table returns the exact RPM,
temperature, voltage, and current thresholds at which relay protection trips.

Example injection:

```
/report?asset=x' UNION SELECT name,sql,'x' FROM sqlite_master--
         &from=0&to=9
```

The bug was filed as HEX-1847 in 2019 and closed won't-fix.

### Path traversal in /export

The `/export` endpoint constructs a file path by joining the exports directory
with the caller-supplied tag parameter without sanitisation:

```python
path = os.path.join(EXPORT_DIR, tag)
```

Traversal to the raw database file:

```
/export?tag=../historian.db
```

This returns the entire SQLite database as a download without any
authentication. SQLite databases can be opened locally with `sqlite3` or any
DB browser and inspected without any further exploitation.

The bug was never formally filed. It is mentioned in the on-disk documentation
as known behaviour.

### Credential reuse: database password equals SSH password

The database user `historian` and the SSH account `hist_admin` share the same
password: `Historian2015`. This is noted explicitly in `historian.ini` on the
virtual filesystem:

```ini
[admin]
ssh_user = hist_admin
ssh_pass = Historian2015
notes    = Same password as database: "easier to remember", P.S.
```

An attacker who recovers the database password through SQL injection can
immediately pivot to an interactive shell on the system.

### Weak ingest authentication with no input validation

The `/ingest` endpoint accepts arbitrary time-series data authenticated only
by `hist_read:history2017`. These credentials are documented in the
SCADA server's `/config` endpoint and in `C:\SCADA\Config\scada.ini` on the
SCADA server's virtual filesystem.

Once authenticated, the endpoint writes directly to the `readings` table with
no validation of asset names or values:

```python
db.execute(
    "INSERT INTO readings (timestamp, asset, value, unit) VALUES (?, ?, ?, ?)",
    (data["timestamp"], data["asset"], float(data["value"]), data["unit"]),
)
```

An attacker can inject false readings for any asset, which will appear on the
SCADA dashboard as real plant data. Ticket HEX-2847 (add input validation) was
closed won't-fix in 2020.

### Alarm configuration table exposed via SQL injection

The `alarm_config` table stores the exact trip thresholds used by the relay
IEDs and PLC safety interlocks. An attacker reading this table learns:

| asset              | lo_lo  | lo     | hi     | hi_hi  | unit | note                             |
|--------------------|--------|--------|--------|--------|------|----------------------------------|
| turbine_rpm        | 2700.0 | 2850.0 | 3150.0 | 3300.0 | RPM  | Overspeed trip at hi_hi          |
| turbine_temperature|  380.0 |  400.0 |  460.0 |  490.0 | C    | Overtemp trip at hi_hi           |
| turbine_pressure   |   70.0 |   78.0 |   90.0 |   95.0 | bar  | Overpressure trip at hi_hi       |
| line_voltage_a     |  184.0 |  196.0 |  253.0 |  264.0 | V    | Relay HR[0]=undervoltage thresh  |
| line_current_a     |    0.0 |    0.0 |  180.0 |  200.0 | A    | Relay HR[1]=overcurrent thresh   |

This gives an attacker the exact register values to write to the relay IEDs to
disable protection, or to the PLC to force a deliberate trip.

## Real-world vulnerabilities / CVEs

| Weakness                         | CVE / Reference                    | Notes                                                                             |
|----------------------------------|------------------------------------|-----------------------------------------------------------------------------------|
| SQL injection in web interface   | CVE-2019-13945                     | Siemens SIMATIC S7: injection in web query parameters                             |
| SQLi in industrial historian     | CVE-2021-27663                     | Wonderware Historian: unauthenticated SQL injection                               |
| Path traversal in file serving   | CVE-2019-10969                     | Moxa MXView: path traversal in file download endpoint                             |
| Credential reuse across services | ICS-CERT Advisory ICSA-19-274-01   | Documented pattern: shared credentials between database and management interfaces |
| No authentication on read API    | CWE-306                            | Missing authentication for critical function: unauthenticated data access        |
| Unauthenticated data injection   | CWE-20                             | Improper input validation: attacker can write arbitrary plant readings           |

## Artefacts attackers should find

### Port scan

```
22/tcp   open  ssh
8080/tcp open  http
```

Banner on SSH identifies Windows Server 2019. The web service returns
`X-Powered-By: Hex-Historian/1.4 Flask/2.3` in response headers.

### Web service enumeration

```
/status       — {"status": "ok", "readings": 43200}
/assets       — turbine_rpm, turbine_temperature, turbine_pressure,
                line_voltage_a, line_current_a, line_voltage_b, line_current_b,
                meter_power_kw, turbine_frequency_hz, oil_pressure
```

### Virtual filesystem (SSH login as hist_admin / Historian2015)

```
C:\Historian\Config\historian.ini       — database + ingest + SSH credentials
C:\Historian\Config\data_sources.xml    — Modbus polling targets (PLC IPs)
C:\Historian\Data\README.txt            — schema notes, path traversal hint
C:\Historian\Archive\export_schedule.txt — nightly export schedule, traversal note
```

PSReadLine history reveals prior queries, including direct SQLite access.

## Historian folder tree

```
/opt/winsvr/C/
├── Historian/
│   ├── Config/
│   │   ├── historian.ini           # credentials: Historian2015, history2017
│   │   └── data_sources.xml        # PLC Modbus polling: 10.10.3.21, 10.10.3.33
│   ├── Data/
│   │   └── README.txt              # schema notes, traversal: tag=../historian.db
│   └── Archive/
│       └── export_schedule.txt     # export filenames + traversal hint
└── Users/
    └── hist_admin/
        ├── Desktop/
        │   └── README.txt          # web endpoints quick reference
        └── AppData/…/PSReadLine/
            └── ConsoleHost_history.txt  # prior queries incl. sqlite3

/opt/historian/data/
├── historian.db                    # SQLite: readings, alarm_config, config tables
└── exports/
    ├── turbine_rpm.csv
    ├── line_voltage_a.csv
    ├── line_voltage_b.csv
    └── line_current_a.csv          # served by /export; traversal reaches ../
```

Example content snippets:

* `C:\Historian\Config\historian.ini`

  ```ini
  [database]
  path     = C:\Historian\Data\historian.db
  user     = historian
  password = Historian2015

  [ingest]
  user     = hist_read
  password = history2017

  [admin]
  ssh_user = hist_admin
  ssh_pass = Historian2015
  notes    = Same password as database: "easier to remember", P.S.
  ```

* SQL injection: enumerate tables:

  ```
  /report?asset=x' UNION SELECT name,sql,'x' FROM sqlite_master--&from=0&to=9
  ```

* Path traversal: download raw database:

  ```
  /export?tag=../historian.db
  ```

## Role in the simulator

The historian is the information hub of the operational zone. It connects the
SCADA dashboard to the raw plant data, the engineering workstation to the export
stream, and the RTU ingest pipeline to the time-series record.

Its SQL injection and path traversal vulnerabilities make it the natural second
exploitation target after gaining access to the enterprise zone. Compromising the
historian does not directly affect the physical process, but it reveals everything
needed to do so precisely.

```
discover historian via bursar-desk ops-access.conf
        ↓
unauthenticated /assets and /status confirm it is alive
        ↓
SQLi in /report → read alarm_config table
        → learn exact RPM/voltage/current trip thresholds
        ↓
SQLi → read config table → recover Historian2015
        ↓
SSH as hist_admin (same password) → interactive shell
        ↓
/export?tag=../historian.db → download full database offline
        ↓
inject false readings via /ingest (hist_read:history2017)
        → SCADA dashboard shows attacker-controlled values
```
