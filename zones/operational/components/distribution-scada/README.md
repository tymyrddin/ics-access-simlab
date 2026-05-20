# Distribution SCADA server

The `distribution-scada` component is the operational zone SCADA at `10.10.2.20`.
It aggregates plant state from `uupl-historian` and presents it as an operator dashboard.
SSH on port 22 drops into a Windows Server 2016 facade.

## Container details

Base image: `debian:bookworm-slim`. Flask web interface on port 8080. SSH on port 22
with a Windows Server 2016 facade (`winserver2016_shell.sh`). stunnel client connects
to `uupl-modbus-gw:8502` for Modbus-TLS; the client key is world-readable at startup
(HEX-5103, risk accepted 2020).

User: `scada_admin`, password `W1nd0ws@2016`. Web credentials: `admin` / `admin`.

Environment variables: `HISTORIAN_IP` (default `10.10.2.10`), `STUNNEL_GW_IP` (default
`10.10.2.50`).

Exposed ports: 22 (SSH), 8080 (web UI).

## Web endpoints

| Endpoint          | Auth        | Notes                                           |
|-------------------|-------------|-------------------------------------------------|
| `/`               | admin/admin | Live dashboard, polls historian for plant state |
| `/config`         | admin/admin | Credential dump: historian, SMTP, web creds     |
| `/historian-pass` | admin/admin | Proxies a historian `/report` query             |

All responses carry `X-Powered-By: UU-SCADA/2.1 Flask/2.3 Python/3.11`.

## Virtual filesystem (SSH)

```
C:\SCADA\Config\scada.ini          all credentials including SSH password
C:\SCADA\Config\alarm_recipients.txt
C:\SCADA\Scripts\send_alarm.bat    SMTP credentials (plantmail123)
C:\SCADA\Scripts\poll_historian.ps1 historian credentials (hist_read/history2017)
C:\SCADA\Logs\alarm_log_2026.txt   trip events with threshold values
```

PSReadLine history includes prior historian queries and SSH sessions.

## Attack chain summary

See `scada-server.md` for the full device runbook.

```
default web creds admin/admin
    → /config endpoint: hist_read/history2017 + plantmail123
    → SSH as scada_admin (W1nd0ws@2016 from scada.ini)
    → /run/stunnel-certs/client.key (world-readable, HEX-5103)
    → direct Modbus-TLS to uupl-modbus-gw → PLC commands
```
