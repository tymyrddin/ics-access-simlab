# Infrastructure: network topology and firewall posture

Five zones, five routers, several intentional bypasses. The zones are implemented
as Linux bridges (`ics_internet`, `ics_dmz`, `ics_enterprise`, `ics_operational`,
`ics_control`, `ics_wan`). The routers are FRR containers, each dual-homed between
two adjacent zones, running iptables FORWARD rules that encode the inter-zone policy.

A realistic posture is less "strict Purdue diagram purity" and more "layers with
operational shortcuts and historical scars". Segmentation exists. Policy exists.
Violations are operationally motivated. The attack paths emerge from accumulated
exceptions rather than cartoon negligence. Nobody woke up wanting flat insecure OT;
they woke up wanting telemetry working before the morning meeting.

## Zones and address ranges

| Zone        | Bridge             | Range           |
|-------------|--------------------|-----------------|
| Internet    | `ics_internet`     | 10.10.0.0/24    |
| DMZ         | `ics_dmz`          | 10.10.5.0/24    |
| Enterprise  | `ics_enterprise`   | 10.10.1.0/24    |
| Operational | `ics_operational`  | 10.10.2.0/24    |
| Control     | `ics_control`      | 10.10.3.0/24    |
| Field / WAN | `ics_wan`          | 10.10.4.0/24    |

## Routers and their positions

| Router           | Zone A side        | Zone B side        | ACL script                                |
|------------------|--------------------|--------------------|-------------------------------------------|
| `inet-dmz-fw`    | 10.10.0.200 (inet) | 10.10.5.200 (dmz)  | `routers/generated/inet-dmz-fw-acl.sh`    |
| `dmz-ent-fw`     | 10.10.5.201 (dmz)  | 10.10.1.201 (ent)  | `routers/generated/dmz-ent-fw-acl.sh`     |
| `ent-ops-fw`     | 10.10.1.202 (ent)  | 10.10.2.202 (ops)  | `routers/generated/ent-ops-fw-acl.sh`     |
| `ops-ctrl-fw`    | 10.10.2.203 (ops)  | 10.10.3.203 (ctrl) | `routers/generated/ops-ctrl-fw-acl.sh`    |
| `ops-wan-router` | 10.10.2.204 (ops)  | 10.10.4.204 (wan)  | `routers/generated/ops-wan-router-acl.sh` |

All routers are built from `infrastructure/routers/Dockerfile` (FRR + iptables + sshd).
The ACL scripts are applied by the router's entrypoint and establish the FORWARD policy.
All routers default to DROP for unmatched forwarded traffic.

## Zone-to-zone reachability

What the firewalls actually permit. ESTABLISHED/RELATED return traffic is always
accepted; this table covers new connection initiation.

| From           | To             | What is permitted                                              |
|----------------|----------------|----------------------------------------------------------------|
| Internet       | DMZ            | All traffic (inet-dmz-fw: open attack surface by design)       |
| Internet       | Enterprise     | Blocked                                                        |
| Internet       | Operational    | Blocked                                                        |
| Internet       | Control        | Blocked                                                        |
| Internet       | Field          | Blocked                                                        |
| DMZ            | Internet       | Return traffic only                                            |
| DMZ            | Enterprise     | Blocked except: contractors-gate (10.10.5.20) → all enterprise |
| DMZ            | Operational    | historian:8080 and SCADA:8080 only                             |
| DMZ            | Control        | Blocked                                                        |
| Enterprise     | DMZ            | Return traffic only; no new connections permitted              |
| Enterprise     | Operational    | historian:8080, SCADA:8080, eng-ws:22                          |
| Enterprise     | Control        | Blocked                                                        |
| Operational    | DMZ            | eng-ws (10.10.2.30) → all DMZ; all other operational blocked   |
| Operational    | Enterprise     | Blocked (explicit DROP)                                        |
| Operational    | Control        | eng-ws (10.10.2.30) → Modbus TCP (502) only                    |
| Operational    | Field          | SCADA and eng-ws → Modbus TCP (502) and SNMP UDP (161)         |
| Control        | Operational    | Blocked (explicit DROP)                                        |
| Control        | Any other      | Blocked                                                        |
| Field          | Operational    | Blocked (explicit DROP)                                        |
| Field          | Any other      | Blocked                                                        |

## Direct-attachment bypasses

Several hosts are dual- or triple-homed. Their additional interfaces are directly
attached to another zone's bridge, bypassing the firewall between those zones entirely.
This is the realistic weakness: protocol-specific allow rules become de facto trust
relationships, and direct-attachment shortcuts bypass even those.

| Host               | Primary zone | Additional interfaces                   | Bypass effect                                                                                     |
|--------------------|--------------|-----------------------------------------|---------------------------------------------------------------------------------------------------|
| `wizzards-retreat` | Internet     | 10.10.1.3 (enterprise), 10.10.2.3 (ops) | Bypasses dmz-ent-fw and ent-ops-fw entirely. Directly reachable on three segments from one shell. |
| `bursar-desk`      | Enterprise   | 10.10.2.100 (operational)               | Bypasses ent-ops-fw. Direct path to historian and SCADA.                                          |
| `contractors-gate` | DMZ          | 10.10.1.30 (enterprise)                 | Bypasses dmz-ent-fw for enterprise-bound traffic. Bastion pivot.                                  |
| `uupl-eng-ws`      | Operational  | 10.10.3.100 (control)                   | Bypasses ops-ctrl-fw. Direct access to all control zone devices.                                  |
| `uupl-modbus-gw`   | Operational  | 10.10.3.50 (control)                    | Bridges operational and control zones (stunnel TLS gateway).                                      |

## Per-zone posture

### Internet (10.10.0.0/24)

Attacker origin and one intentionally-exploitable admin machine.

`unseen-gate` (10.10.0.5) is the attacker's starting position. Single-homed.
Can reach all DMZ services (inet-dmz-fw is open) and, from there, pivot further.

`wizzards-retreat` (10.10.0.10) is the realistic home-admin machine: a "temporary"
remote access bridge from 2019 that became permanent. Triple-homed. Its three NICs
effectively bypass every inter-zone firewall between internet, enterprise, and
operational. This is framed as a home support appliance or legacy contractor VPN
replacement, not negligence: the operational access was added incrementally and
never revoked.

### DMZ (10.10.5.0/24)

Protocol translation, telemetry brokering, contractor ingress. This zone is the
boundary between IT and OT, and it has accumulated exactly the mixture of services
you would expect: MQTT, OPC-UA bridge, protocol gateway, SFTP drop, syslog relay,
DNS, NTP, and a bastion SSH server.

The realistic weakness here is that protocol-specific allow rules between DMZ and
operational become de facto trust. Once the DMZ → historian and DMZ → SCADA HTTP
rules exist, any DMZ host that is compromised can query operational data without
crossing another firewall.

`contractors-gate` (10.10.5.20 / 10.10.1.30) is dual-homed and acts as the pivot
into enterprise. An attacker who compromises it has direct access to the enterprise
segment from the enterprise NIC.

### Enterprise (10.10.1.0/24)

Normal corporate workstations plus accumulated exceptions.

Internet access is not explicitly firewalled outbound from enterprise (no matching
rule exists for enterprise → internet), but `wizzards-retreat` handles internet
connectivity via its 10.10.0.10 interface. The enterprise-to-operational rules
are narrow on paper (historian:8080, SCADA:8080, eng-ws:22), but `bursar-desk`
is dual-homed at 10.10.2.100 and bypasses those rules entirely.

`hex-legacy-1` (10.10.1.10) and `bursar-desk` (10.10.1.20) are the main lateral
movement targets. `bursar-desk` is the pivot into operational.

### Operational (10.10.2.0/24)

Historian, SCADA, engineering workstation. This zone is softer internally than
the policy documents claim.

`uupl-eng-ws` (10.10.2.30 / 10.10.3.100) is dual-homed and has the only firewall-
permitted path from operational to control zone (Modbus TCP 502). Its control-zone
NIC bypasses ops-ctrl-fw entirely for hosts it can reach directly.

Outbound telemetry to DMZ is allowed specifically for eng-ws. All other operational
hosts are blocked from initiating connections anywhere outside the zone.
Operational hosts cannot initiate connections to enterprise (explicit DROP rule).

`uupl-modbus-gw` (10.10.2.50 / 10.10.3.50) bridges operational and control via a
stunnel TLS tunnel. It is directly attached to both zones and bypasses ops-ctrl-fw.

### Control (10.10.3.0/24)

PLCs, turbine logic, relays, HMI, actuators, MQTT broker.

Explicit DROP for all control → operational traffic. The only permitted inbound
path is eng-ws:502 through ops-ctrl-fw, plus direct-attachment bypasses from
uupl-eng-ws (10.10.3.100) and uupl-modbus-gw (10.10.3.50).

In practice, eng-ws has a directly-attached NIC here and can reach every device
on the segment without going through the firewall.

### Field / WAN (10.10.4.0/24)

Remote RTUs and field devices. Only SCADA (10.10.2.20) and eng-ws (10.10.2.30)
may initiate connections here: Modbus TCP 502 and SNMP UDP 161. Field devices
cannot initiate connections back. Explicit DROP on WAN → operational.

## Changing the firewall rules

The ACL scripts in `routers/generated/` are generated by `orchestrator/generate.py`
from `orchestrator/ctf-config.yaml`. Edit them there to keep generate.py as the
source of truth, or edit the scripts directly if the change is temporary or
lab-specific.

To reload rules on a running router without cycling the lab:

```bash
docker exec inet-dmz-fw sh /acl.sh
```

Replace `inet-dmz-fw` with the router name and `/acl.sh` with the path where the
entrypoint copies the script (check `routers/entrypoint.sh` for the exact path).

To rebuild the router image after changing the Dockerfile:

```bash
docker build -t dmz-router infrastructure/routers/
```

The image name is shared across all router containers; they are differentiated by
which ACL script is mounted or baked in at deploy time.

## clab topology files

The containerlab topology files that wire zones together are in `clab/`:

```
clab/internet-zone.clab.yaml
clab/dmz-zone.clab.yaml
clab/enterprise-zone.clab.yaml
clab/operational-zone.clab.yaml
clab/control-zone.clab.yaml
```

Each file defines the nodes on that zone's bridge plus their veth links to the
shared routers. `./ctl up` runs `infrastructure/clab-up.sh`, which deploys all
five topology files in sequence.
