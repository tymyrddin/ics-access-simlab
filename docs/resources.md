# Simulator ics-simlab

[https://github.com/tymyrddin/ics-simlab](https://github.com/tymyrddin/ics-simlab)

Component containers across three network zones (enterprise, operational, control), separated by
iptables firewall rules with specific allowed paths. A Python orchestrator generates all Docker
Compose files and firewall rules from a single YAML configuration. Hardware-in-the-loop physics
simulation models a turbine at the Unseen University Power and Light facility. Attacks have
observable physical consequences.

Techniques reference the categories in [attack-surface.md](../attack-surface.md).

Requirements: Linux (Ubuntu 22.04 or Debian 12), Docker Engine 24+, Docker Compose v2.20+,
Python 3.10+. Minimum 4 GB RAM, 2 cores, 10 GB disk; 8 GB RAM and 4 cores recommended.

## Network topology

| Zone        | Subnet       | Components                                          |
|:------------|:-------------|:----------------------------------------------------|
| Internet    | 10.10.0.0/24 | jump-host (entry point, SSH key auth)               |
| Enterprise  | 10.10.1.0/24 | legacy-workstation, enterprise-workstation          |
| Operational | 10.10.2.0/24 | historian, SCADA server, engineering-workstation    |
| Control     | 10.10.3.0/24 | turbine-plc, HMI, IED relays, meter, four actuators |

Inter-zone routing is controlled by generated iptables rules. Enterprise can reach the
operational zone's web interfaces and the engineering workstation via SSH. The engineering
workstation has Modbus access to the control zone. All other cross-zone traffic is dropped.

## Enterprise zone

### Legacy workstation (hex-legacy-1, 10.10.1.10)

Services: SMB, FTP (anonymous access enabled), Telnet, SSH with weak password (hex123).

Vulnerabilities:
* LM and NTLM hashes exposed via SMB; crackable with offline tools (trust exploitation)
* Anonymous FTP access; network inventory and operational SOPs readable without credentials
  (data exfiltration, trust exploitation)
* Telnet credentials transmitted in plaintext (trust exploitation)
* Hardcoded credentials in shared files on SMB shares (data exfiltration, trust exploitation)

Attack path: protocol enumeration → hash capture or anonymous FTP → credential harvesting →
access operational documentation.

### Enterprise workstation (bursar-desk, 10.10.1.20)

Dual-homed: 10.10.1.20 (enterprise) and 10.10.2.100 (operational). SSH with weak password
(Octavo1), password authentication enabled.

Vulnerabilities:
* Plaintext credentials in `~/.config/ops-access.conf`: historian and SCADA passwords stored
  in clear (data exfiltration, trust exploitation)
* Hardcoded credentials in shell scripts: `pull_monthly_report.sh` contains Historian2015
  (data exfiltration, trust exploitation)
* Shell history exposes internal IPs and operational hostnames (data exfiltration)
* Dual-homed network placement enables pivot to operational zone (lateral movement)

Attack path: SSH compromise (Octavo1) → credential discovery in config files and scripts →
pivot to historian and SCADA.

## Operational zone

### Historian (uupl-historian, 10.10.2.10)

Services: Flask HTTP on port 8080, SSH on port 22. SQLite time-series database.

Vulnerabilities:
* SQL injection in `/report` endpoint: `asset` parameter interpolated directly into SQL;
  error messages returned verbatim, disclosing schema and table names; `alarm_config` table
  reveals exact relay trip thresholds (data exfiltration, trust exploitation)
* Path traversal in `/export` endpoint: `tag=../historian.db` returns the raw SQLite database
  without credentials (data exfiltration)
* Credential reuse: SSH account `hist_admin` and database user `historian` share password
  Historian2015 (trust exploitation, lateral movement)
* Weak ingest authentication: `/ingest` accepts arbitrary time-series data with minimal
  credentials (hist_read:history2017); no input validation; allows injection of false plant
  readings into the SCADA dashboard (data integrity manipulation)

Attack path: `/assets` and `/status` recon → SQLi on `/report` to extract alarm thresholds
and credentials → SSH access → database download → false data injection via `/ingest`.

### SCADA server (distribution-scada, 10.10.2.20)

Services: Flask HTTP on port 8080, SSH on port 22.

Vulnerabilities:
* Default credentials never changed: admin/admin (trust exploitation)
* `/config` endpoint returns a plaintext dump of all stored credentials including historian
  password, SMTP credentials, and SCADA SSH credentials (data exfiltration)
* Version and stack disclosure via `X-Powered-By` response header (process intelligence)
* `/historian-pass` endpoint proxies historian queries without further authentication; added
  by an engineer who forgot the historian password (trust exploitation)
* SSH credentials in virtual config file path `C:\SCADA\Config\scada.ini` containing
  scada_admin:W1nd0ws@2016 (data exfiltration)
* SMTP credential reuse: plantmail123 appears in `/config`, batch scripts, and engineering
  workstation files (trust exploitation)

Attack path: default web login → `/config` endpoint → extract all credentials → SSH access.

### Engineering workstation (uupl-eng-ws, 10.10.2.30)

Dual-homed: 10.10.2.30 (operational) and 10.10.3.100 (control). SSH with password
spanner99, also reachable via credential pivot from bursar-desk.

Vulnerabilities:
* `engineering_notes.txt` lists all zone credentials explicitly in plaintext (data exfiltration, trust exploitation)
* PLC project files contain turbine_admin:turbineadmin in plaintext (data exfiltration)
* `PLC_Backup_2019.tar.gz`: unencrypted archive containing full 2019 network map and all
  credentials (data exfiltration, trust exploitation)
* Firmware update script hardcodes PLC password and prints it to stdout (data exfiltration)
* Pre-configured Modbus tools: `modbus_read.py` and `modbus_write.py` are immediately
  functional, pointed at the control zone, requiring no setup (lateral movement)
* Relay configuration files `relay_a_2019.txt` and `relay_b_2019.txt` document all
  protection thresholds with notes on manipulation (process intelligence, data exfiltration)
* Direct unrestricted Modbus access from 10.10.3.100 to the entire control zone (lateral movement)

Attack path: SSH compromise → read engineering notes → use pre-configured Modbus tools
against control zone without additional lateral movement.

## Control zone

### Turbine PLC (hex-turbine-plc, 10.10.3.21)

Services: Modbus TCP on port 502, DNP3 on port 20000, IEC-104 on port 2404, SNMP on port 161.

Vulnerabilities:
* No Modbus authentication: any network host reads and writes all registers and coils
  (state manipulation, process intelligence)
* Emergency stop via coil 0: writing 1 immediately trips the turbine; observable via physics
  engine (state manipulation, denial of control)
* Governor override via holding register 1: writing 100 sets fuel valve to maximum, driving
  RPM above rated speed toward overspeed trip (state manipulation)
* Protection threshold manipulation via holding register 3: writing 0 sets overcurrent
  threshold to zero, causing any load to trip the relay (control logic manipulation)
* No DNP3 authentication: responds to all queries from any host (state manipulation, process intelligence)
* No IEC-104 authentication: substation automation accepts standard APDU frames (state manipulation, process intelligence)
* Default SNMP community strings: public (read), private (read-write) (process intelligence, trust exploitation)

Physics consequences: RPM, temperature, pressure, and breaker state respond in real time to
register writes. Overspeed, overtemperature, and overpressure trip safety interlocks.

### HMI (uupl-hmi, 10.10.3.10)

Services: SSH on port 22, Flask HTTP on port 8080, Modbus proxy on port 502.

Vulnerabilities:
* Default SSH credentials: operator:operator, provisioned for testing, never changed
  (trust exploitation, lateral movement)
* Restricted shell escape: `hmi_shell.py` is Python; CTRL-C exception handling drops to a
  Python REPL; standard shell escape techniques apply (lateral movement)
* Flask secret key hardcoded as `uuplhmi2003`; allows session cookie forgery without valid
  credentials (trust exploitation)
* Unauthenticated Modbus proxy on port 502: forwards writes directly to the PLC without
  authentication or rate limiting; bypasses need for direct control zone access (state manipulation, trust exploitation)
* Web interface page source discloses PLC IP address 10.10.3.21 (process intelligence)

Attack path: default SSH → shell escape → full container access; or forge session cookie via
known Flask secret; or issue Modbus writes through the HMI proxy.

### IED relays (uupl-relay-a, 10.10.3.31 / uupl-relay-b, 10.10.3.32)

Two protective relay IEDs. Each polls the turbine PLC every 500 ms and trips its associated
breaker on threshold breach.

Services per relay: Modbus TCP on port 502, HTTP on port 8081, SNMP on port 161.

Vulnerabilities:
* Writable protection thresholds via Modbus with no authentication: raising undervoltage
  threshold `HR[0]` to nominal voltage causes immediate spurious trip; lowering overcurrent
  threshold `HR[1]` to 1A trips on any load; setting overspeed threshold `HR[2]` to 0 trips
  immediately (state manipulation, denial of control)
* Force-trip via coil 0: writing 1 activates trip flag and sends breaker trip command
  (state manipulation, denial of control)
* Auto-reclose race condition: continuously writing coil 0 = 1 prevents breaker from
  reclosing, keeping the feeder offline indefinitely (denial of control)
* Default web credentials admin:relay1234, no rate limiting; post-login access to threshold
  configuration and force-trip button (trust exploitation)
* Trip log exposed without authentication: last 50 events including cause, voltage, current,
  RPM (process intelligence, data exfiltration)
* Default SNMP community strings (process intelligence, trust exploitation)

### Revenue meter (uupl-meter, 10.10.3.33)

Services: Modbus TCP on port 502 (read-only), SNMP on port 161.

Vulnerabilities:
* Unauthenticated Modbus read: all five input registers accessible without credentials;
  confirms turbine state and live process values without requiring direct PLC access
  (process intelligence, data exfiltration)
* Default SNMP community strings: public and private (process intelligence, trust exploitation)
* Meter readings derived from PLC data: falsified PLC values propagate directly to meter
  readings, making the meter an unreliable source of truth after upstream manipulation
  (data integrity manipulation, indirect)

### Actuators (10.10.3.51-54)

Four actuators: fuel valve (uupl-fuel-valve), cooling pump (uupl-cooling-pump), breaker A
(uupl-breaker-a, Dolly Sisters feeder), breaker B (uupl-breaker-b, Nap Hill feeder).

Services: Modbus TCP on port 502.

Vulnerabilities:
* Unauthenticated Modbus writes on all actuators: any host in the control zone writes
  registers and coils directly (state manipulation, denial of control)
* Direct breaker control: coil 1 trips breaker, coil 2 closes it; bypasses PLC control loop (state manipulation, denial of control)
* Fuel valve override: writing holding register 0 fights the governor; 0 cuts fuel, 100 sets
  maximum; RPM drops or climbs accordingly (state manipulation)
* Cooling pump speed control: writing holding register 0 to 0 stops cooling; temperature
  rises until overtemperature interlock fires (state manipulation, denial of control)

## Done

* Zone-to-zone lateral movement via engineering workstation pivot (lateral movement)
* Historian SQL injection, path traversal, credential reuse, false data injection
  (data exfiltration, data integrity manipulation, trust exploitation)
* IED relay threshold manipulation, force-trip, auto-reclose race (state manipulation, denial of control)
* IED relay web default credentials (trust exploitation)
* IED relay trip log without authentication (process intelligence, data exfiltration)
* Legacy workstation credential harvesting via legacy protocols (data exfiltration, trust exploitation, lateral movement)
* Enterprise workstation pivot via plaintext credential files (data exfiltration, trust exploitation, lateral movement)
* SCADA server default credentials and credential disclosure (data exfiltration, trust exploitation)
* Engineering workstation Modbus access to control zone (state manipulation, process intelligence, lateral movement)
* Turbine PLC unauthenticated Modbus, DNP3, IEC-104 (state manipulation, process intelligence)
* HMI default credentials, shell escape, Modbus proxy (state manipulation, trust exploitation, lateral movement)
* Actuator direct control (state manipulation, denial of control)
* Revenue meter unauthenticated read (process intelligence, data exfiltration)
* Physics engine real-time response to all control zone attacks (state manipulation consequences)

## Feasible

* Full chain Realist: enterprise entry to turbine trip via all three zones
* False data injection with visible physics consequence: historian poisoning currently
  affects SCADA display; physics engine does not yet consume injected values as real sensor
  input (data integrity manipulation gap)
* SCADA server: enterprise-workstation and scada-server vulnerability surfaces present but
  not fully validated as standalone challenge artefacts
* Protocol traffic captures: any of the above attack paths can be captured as PCAP artefacts
  for Network challenges; not yet generated and validated

## Challenge inventory

| Component               | Technique                                                                               | Category | Difficulty   | Status   |
|:------------------------|:----------------------------------------------------------------------------------------|:---------|:-------------|:---------|
| Legacy workstation      | lateral movement, trust exploitation                                                    | Network  | Beginner     | Ready    |
| Legacy workstation      | data exfiltration                                                                       | Network  | Beginner     | Ready    |
| Enterprise workstation  | data exfiltration, trust exploitation, lateral movement                                 | Forensic | Intermediate | Ready    |
| Historian               | data exfiltration (SQLi)                                                                | Network  | Intermediate | Ready    |
| Historian               | data exfiltration (traversal)                                                           | Network  | Intermediate | Ready    |
| Historian               | data integrity manipulation                                                             | Realist  | Intermediate | Ready    |
| SCADA server            | trust exploitation, data exfiltration                                                   | Network  | Beginner     | Feasible |
| Engineering workstation | lateral movement                                                                        | Realist  | Intermediate | Ready    |
| Turbine PLC             | process intelligence                                                                    | Network  | Beginner     | Ready    |
| Turbine PLC             | state manipulation                                                                      | Network  | Intermediate | Ready    |
| Turbine PLC             | denial of control                                                                       | Realist  | Intermediate | Ready    |
| Turbine PLC             | control logic manipulation                                                              | Realist  | Advanced     | Ready    |
| IED relay               | process intelligence, data exfiltration                                                 | Network  | Beginner     | Ready    |
| IED relay               | state manipulation                                                                      | Network  | Intermediate | Ready    |
| IED relay               | denial of control                                                                       | Realist  | Advanced     | Ready    |
| HMI                     | trust exploitation, lateral movement                                                    | Realist  | Intermediate | Ready    |
| HMI                     | trust exploitation (session forgery)                                                    | Network  | Intermediate | Ready    |
| Revenue meter           | process intelligence, data exfiltration                                                 | Network  | Beginner     | Ready    |
| Actuators               | state manipulation, denial of control                                                   | Realist  | Intermediate | Ready    |
| Full chain              | lateral movement → data exfiltration → data integrity manipulation → state manipulation | Realist  | Advanced     | Feasible |
