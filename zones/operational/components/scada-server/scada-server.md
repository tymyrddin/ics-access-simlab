# SCADA Server: SCADA-SRV01

## Device description

The UU P&L Distribution SCADA server is the operational overview system for the
city-wide power distribution network. It aggregates data from the historian,
presents a live dashboard of plant measurements, and drives the alarm relay
pipeline when trip conditions are detected.

The container presents as a Windows Server 2016 system. SSH on port 22 accepts
password authentication and drops the user into a PowerShell facade. The web
dashboard runs on port 8080 behind HTTP Basic Auth.

The authentication was added in response to a query from the Patrician's office
asking whether the power grid status page really needed to be visible on the
network without a password. The password set at the time has not changed.

From an attacker's perspective, the SCADA server is primarily a credential
aggregation point. The web dashboard is protected by the weakest possible
credentials. Behind those credentials, the `/config` endpoint returns the
historian read password, the SMTP alarm relay password, and the web interface
credentials themselves in plaintext. The virtual filesystem contains a full
connection configuration file and a batch alarm script exposing the same SMTP
credentials in a different location.

The SCADA server also sits in the operational zone with SSH access, making it a
usable pivot host once its credentials are obtained from the engineering
workstation or via the historian.

## Container behaviour

The container exposes two network services:

* SSH on port 22: password authentication, Windows Server 2016 facade shell
* Flask web service on port 8080: HTTP Basic Auth on most endpoints

Web service endpoints:

| Endpoint          | Method | Auth        | Description                                      |
|-------------------|--------|-------------|--------------------------------------------------|
| `/`               | GET    | admin/admin | Live dashboard, polls historian for plant state  |
| `/config`         | GET    | admin/admin | Connection config dump with credentials          |
| `/historian-pass` | GET    | admin/admin | Proxies historian SQLi-exploitable /report call  |
| 404 and others    | —      | —           | `X-Powered-By` header present on all responses   |

The virtual Windows filesystem is mounted at `/opt/winsvr/C`. The shell
presents this as `C:\`. A connection config file, alarm scripts, and PSReadLine
history are discoverable through the facade after SSH login.

## Deliberately introduced vulnerabilities

### Default web credentials

The dashboard is protected by `admin / admin`. These were set during initial
installation and never changed, documented in `scada.ini` on the virtual
filesystem:

```ini
[scada_web]
host     = 10.10.2.20
port     = 8080
user     = admin
password = admin
```

The credentials are also visible in the engineering workstation's
`engineering_notes.txt` and in `ops-access.conf` on the Bursar's workstation.

### /config endpoint: full credential disclosure

The `/config` endpoint is protected by the same `admin/admin` credentials.
It returns a plaintext configuration dump containing:

```ini
[historian]
host     = 10.10.2.10
port     = 8080
user     = hist_read
password = history2017

[alarm_smtp]
host     = mail.uu.am
port     = 587
user     = alarms@uupl.am
password = plantmail123

[scada]
web_user = admin
web_pass = admin
```

The endpoint was added during commissioning of the monitoring agent integration
and was supposed to be removed after go-live. It was not.

### /historian-pass endpoint: credential proxy

The `/historian-pass` route was added by an engineer who kept forgetting the
historian password. It proxies the result of a historian `/report` query back
to the caller. Behind the minimal protection of `admin/admin`, anyone who knows
to call this URL gets indirect access to the historian.

The route has never been removed.

### X-Powered-By version disclosure

Every response includes:

```
X-Powered-By: UU-SCADA/2.1 Flask/2.3 Python/3.11
```

Version information assists attackers in identifying relevant vulnerabilities
and confirms the application framework without any directory enumeration.

### SSH credentials in virtual filesystem

The virtual `C:\SCADA\Config\scada.ini` file contains the SSH account
credentials alongside the service credentials:

```ini
[scada_admin]
ssh_user = scada_admin
ssh_pass = W1nd0ws@2016
notes    = Windows admin account. Set at installation. IT asked about
           rotating it in 2022. Ticket raised. Ticket closed. Not rotated.
```

### SMTP alarm credentials in alarm scripts

The alarm relay batch script and the shell script used at runtime both contain
the SMTP password in plaintext:

```bat
set SMTP_PASS=plantmail123
```

```bash
SMTP_PASS="plantmail123"
```

The same credential appears in the `/config` endpoint, the `scada.ini` virtual
file, and the engineering workstation's `send_alarm.ps1`. This cross-system
credential reuse means recovering the SMTP password from any one location is
sufficient.

## Real-world vulnerabilities / CVEs

| Weakness                          | CVE / Reference       | Notes                                                                 |
|-----------------------------------|-----------------------|-----------------------------------------------------------------------|
| Default web credentials           | CVE-2018-10952        | Moxa ActiveOPC: admin/admin on SCADA web interface                    |
| Default credentials in SCADA      | CVE-2019-10915        | Several industrial HMI web interfaces shipped with default creds      |
| Credential disclosure via web API | CVE-2021-22656        | Advantech iView: configuration endpoint exposed credentials           |
| Version disclosure header         | CWE-200               | Information exposure through server headers                           |
| Credential reuse across services  | ICS-CERT ICSA-19-274  | Common OT pattern: shared credentials across historian and SCADA      |
| Hardcoded credentials in scripts  | CVE-2020-5777         | GE Proficy: hardcoded credentials in automation scripts               |

## Artefacts attackers should find

### Port scan

```
22/tcp   open  ssh
8080/tcp open  http
```

The SSH banner presents Windows Server 2016. All HTTP responses include
`X-Powered-By: UU-SCADA/2.1 Flask/2.3 Python/3.11`.

### Unauthenticated header inspection

A bare `curl -I http://10.10.2.20:8080/` returns a 401 with the
`X-Powered-By` header and `WWW-Authenticate: Basic realm="UU P&L SCADA"`.
The realm confirms the application and organisation.

### Authenticated endpoint enumeration (admin/admin)

```
/               — live dashboard with historian IP visible in page source
/config         — full credential dump (hist_read, plantmail123, admin/admin)
/historian-pass — proxied historian response
```

### Virtual filesystem (SSH as scada_admin / W1nd0ws@2016)

```
C:\SCADA\Config\scada.ini            — all credentials incl. SSH password
C:\SCADA\Config\alarm_recipients.txt — ops-duty@uupl.am, ponder.stibbons@uupl.am
C:\SCADA\Scripts\send_alarm.bat      — SMTP credentials (plantmail123)
C:\SCADA\Scripts\poll_historian.ps1  — historian credentials (hist_read/history2017)
C:\SCADA\Logs\alarm_log_2026.txt     — real alarm events, trip threshold values visible
```

PSReadLine history shows prior historian queries and SSH sessions.

## SCADA server folder tree

```
/opt/winsvr/C/
├── SCADA/
│   ├── Config/
│   │   ├── scada.ini               # all credentials: admin/admin, W1nd0ws@2016,
│   │   │                           # hist_read/history2017, plantmail123
│   │   └── alarm_recipients.txt    # notification email addresses
│   ├── Scripts/
│   │   ├── send_alarm.bat          # SMTP creds in plain sight
│   │   └── poll_historian.ps1      # hist_read/history2017
│   └── Logs/
│       └── alarm_log_2026.txt      # trip events with threshold values
└── Users/
    └── scada_admin/
        ├── Desktop/
        │   └── README.txt          # quick reference: web URL, config path
        └── AppData/…/PSReadLine/
            └── ConsoleHost_history.txt  # prior sessions incl. ssh hist_admin@historian

/opt/scada/
└── scripts/
    └── send_alarm.sh               # runtime alarm relay: SMTP_PASS="plantmail123"
```

Example content snippets:

* `C:\SCADA\Config\scada.ini`

  ```ini
  [historian]
  host     = 10.10.2.10
  port     = 8080
  user     = hist_read
  password = history2017

  [scada_web]
  user     = admin
  password = admin

  [alarm_smtp]
  host     = mail.uu.am
  port     = 587
  user     = alarms@uupl.am
  password = plantmail123

  [scada_admin]
  ssh_user = scada_admin
  ssh_pass = W1nd0ws@2016
  ```

* `/config` endpoint response (requires admin/admin):

  ```
  [historian]
  host     = 10.10.2.10
  user     = hist_read
  password = history2017

  [alarm_smtp]
  password = plantmail123

  [scada]
  web_user = admin
  web_pass = admin
  ```

## Role in the simulator

The SCADA server is primarily a credential disclosure point and a lateral
movement target rather than a direct attack vector against the physical process.
Its value to an attacker is the aggregation of credentials from multiple systems
in a single location.

It is also the system that drives alarm notifications. An attacker with control
over the historian `/ingest` endpoint can inject false readings that will suppress
or generate SCADA alarms, potentially masking real operational events.

```
discover SCADA via historian dashboard link or ops-access.conf on bursar-desk
        ↓
default web credentials admin/admin
        ↓
/config endpoint → hist_read/history2017 + plantmail123 + admin/admin confirmed
        ↓
/historian-pass → indirect historian access (useful if direct route blocked)
        ↓
SSH as scada_admin (W1nd0ws@2016 in scada.ini) → interactive shell on ops zone
        ↓
scada.ini → historian credentials → use /ingest to poison plant readings
        → dashboard shows attacker-controlled values
        → real alarms suppressed or false alarms generated
```
