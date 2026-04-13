# DMZ zone

`ics_dmz` (10.10.5.0/24) is the Guild Quarter: the boundary area between Unseen University and Ankh-Morpork proper, 
where institutional and commercial interfaces happen and nobody checks credentials too carefully. It sits between the 
internet zone and the enterprise zone, technically a DMZ, practically an attack surface.

All ten devices are reachable from the internet. They are interesting targets in their own right and relay 
infrastructure for the zones behind them.

## What lives here

| Hostname         | IP         | Role                                                                                                                              |
|------------------|------------|-----------------------------------------------------------------------------------------------------------------------------------|
| guild-exchange   | 10.10.5.10 | umatiGateway. OPC-UA to MQTT bridge. Management UI on :8080, no authentication. CVE-2025-27615.                                   |
| sorting-office   | 10.10.5.11 | Neuron protocol gateway. Modbus south devices bridge to OT networks. Default credentials admin/0000 on :7000.                     |
| clacks-relay     | 10.10.5.12 | Mosquitto MQTT broker. Port 1883, allow_anonymous true. Receives data from the OT data brokers.                                   |
| guild-register   | 10.10.5.13 | OPC-UA demo server. Anonymous authentication, SecurityMode=None, port 4840. Callable methods include stopPump.                    |
| substation-rtu   | 10.10.5.14 | IEC-104 RTU simulator. Port 2404 for IEC-104, port 8080 for a no-authentication REST API that reconfigures datapoints on the fly. |
| contractors-gate | 10.10.5.20 | SSH bastion. OpenSSH 9.2p1-2, CVE-2024-6387 (regreSSHion). PermitRootLogin yes, root/uupl2015. Also on enterprise as 10.10.1.30.  |
| dispatch-box     | 10.10.5.21 | SFTP drop. atmoz/sftp. User anonymous/anonymous, upload directory, no chroot jail.                                                |
| guild-clock      | 10.10.5.30 | NTP server. No NTP authentication. Time manipulation disrupts certificate validation and log correlation.                         |
| city-directory   | 10.10.5.31 | DNS forwarder. BIND9, open recursion, DNSSEC validation off. Cache poisoning is viable.                                           |
| scribes-post     | 10.10.5.32 | Syslog relay. syslog-ng, UDP 514, no TLS, no source authentication. Sniffable and spoofable.                                      |

## Firewall position

The internet zone has open access to the DMZ. This is the intended attack surface.

The DMZ can reach:
- The enterprise zone, but only from `contractors-gate` (10.10.5.20). All other DMZ hosts are blocked from enterprise.
- The historian web UI (10.10.2.10:8080) and operations SCADA web UI (10.10.2.20:8080) in the operational zone.

The DMZ has no path to the control zone or the WAN.

## Attack chains from here

Data broker pivot: `sorting-office` (admin/0000) lets an attacker add a Modbus south device pointing at the turbine PLC. Register reads and writes flow through the gateway without the attacker ever touching the control zone.

umatiGateway pivot: the management UI on `guild-exchange` exposes the full OPC-UA server configuration. Reading it reveals `guild-register` at 10.10.5.13. The OPC-UA server has anonymous auth and directly callable methods, including `stopPump`.

SSH bastion: `contractors-gate` carries CVE-2024-6387. Its enterprise NIC (10.10.1.30) opens the corporate IT zone after exploitation. `AllowAgentForwarding yes` makes it useful as a jump host once root access is established.

DNS poisoning: compromise `city-directory`, poison the historian hostname, intercept historian traffic from enterprise, harvest the database credentials. The historian password is reused as the SSH password for `hist_admin`.

Time manipulation: `guild-clock` accepts unauthenticated NTP configuration. Shifting system time on other devices corrupts log timestamps and causes certificate validation failures, which is less glamorous than remote code execution but genuinely disruptive during incident response.
