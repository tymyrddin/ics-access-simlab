# Operational zone

`ics_operational` (10.10.2.0/24) is the site operations management network. Purdue Level 3. This is where the operations floor lives: the SCADA server operators read in the morning, the historian that stores years of process data, and the engineering workstation that bridges two zones because someone needed to reach both and never revisited the decision.

## What lives here

| Hostname | IP | Role |
|---|---|---|
| uupl-historian | 10.10.2.10 | Process historian. SQLite, Flask REST API. Stores time-series sensor data. |
| scada-db | 10.10.2.19 | MySQL sidecar for the operations Scada-LTS instance. |
| distribution-scada | 10.10.2.20 | Operations Scada-LTS (Mango Automation base). Read-only view of the process; data source is the historian. Default credentials: admin/admin. |
| uupl-eng-ws | 10.10.2.30 | Engineering workstation. Dual-homed into control as 10.10.3.100. Contains every credential needed to reach field devices. |
| uupl-modbus-gw | 10.10.2.50 | Stunnel TLS gateway, operational NIC. Also on control as 10.10.3.50. Terminates mTLS from Scada-LTS and forwards Modbus to the PLC. |

## Firewall position

Operational is reachable from enterprise on three specific ports: historian :8080, SCADA :8080, and engineering workstation :22. Everything else is dropped.

Outbound from operational to control is restricted: only the engineering workstation (10.10.3.100) can reach control devices on Modbus :502. The stunnel gateway is dual-homed, so its control-zone traffic is not subject to this rule.

The DMZ can reach historian :8080 and SCADA :8080, simulating data broker read access.

## Where the good stuff is

The historian carries a Python Flask app with SQL injection in the `/report` endpoint and path traversal in `/export`. The database password is reused as the SSH password for `hist_admin`. The operations Scada-LTS has Groovy script injection (CVE-2021-26828) and default `admin/admin` credentials.

The engineering workstation is the most valuable machine in this zone. It holds `plc-access.conf` (credentials for every control-zone device), a PLC backup archive containing the network map, and an Ed25519 key for the engineer account. Reaching it via SSH from an enterprise host is the intended path into the control zone.

The stunnel gateway client key on the Scada-LTS container is world-readable (HEX-5103). Stealing it and authenticating to the gateway allows direct Modbus writes to the PLC, bypassing everything the SCADA UI would normally enforce.
