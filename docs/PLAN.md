# Development plan

Noted for tomorrow. New repo, clean history, my name only.

## Current phase, control zone protocol expansion and SCADA layer

Steps 1–3c complete. Remaining: 3d (OPC-UA + IEC-104 sidecars).

## Current topology

```
ics_internet (10.10.0.0/24)                     external / city network
  unseen-gate      10.10.0.5   attacker machine (internet only)
  wizzards-retreat 10.10.0.10  admin@home, dual-homed into enterprise (VPN sim)

ics_enterprise (10.10.1.0/24)                   corporate IT  (Purdue L4)
  wizzards-retreat 10.10.1.3   second NIC
  hex-legacy-1     10.10.1.10
  bursar-desk      10.10.1.20 / 10.10.2.100

ics_operational (10.10.2.0/24)                  site operations (Purdue L3)
  uupl-historian   10.10.2.10  process historian (SQLite, time-series)
  scada-db         10.10.2.19  MySQL backing DB for ops Scada-LTS
  distribution-scada 10.10.2.20  Scada-LTS: operations SCADA (read/observe)
  uupl-eng-ws      10.10.2.30 / 10.10.3.100
  uupl-modbus-gw   10.10.2.50 / 10.10.3.50  stunnel TLS gateway (dual-homed)

ics_control (10.10.3.0/24)                      area supervisory + field (Purdue L1-2)
  hmi_main-db      10.10.3.11  MySQL backing DB for control Scada-LTS
  uupl-hmi         10.10.3.10  Scada-LTS: control SCADA/HMI (read+write, admin/admin)
  hex-turbine-plc  10.10.3.21  turbine PLC (Modbus :502, MQTT publish)
  uupl-relay-a     10.10.3.31  protective relay IED: Dolly Sisters feeder
  uupl-relay-b     10.10.3.32  protective relay IED: Nap Hill feeder
  uupl-meter       10.10.3.33  revenue meter IED
  actuators        10.10.3.51-54  iotechsys/pymodbus-sim (HOLDING_REGISTERS / COILS)
  uupl-mqtt        10.10.3.60  Mosquitto broker (allow_anonymous)

ics_dmz (10.10.5.0/24)                         DMZ: Guild Quarter
  guild-exchange   10.10.5.10  umatiGateway (CVE-2025-27615, no auth on UI :8080)
  sorting-office   10.10.5.11  Neuron gateway (admin/0000, protocol bridge :7000)
  clacks-relay     10.10.5.12  MQTT broker (allow_anonymous, port 1883)
  guild-register   10.10.5.13  OPC-UA server (anonymous, SecurityMode=None, :4840)
  substation-rtu   10.10.5.14  IEC-104 RTU (no-auth REST API :8080, IEC-104 :2404)
  contractors-gate 10.10.5.20 / 10.10.1.30  SSH bastion (CVE-2024-6387, root/uupl2015)
  dispatch-box     10.10.5.21  SFTP drop (anonymous/anonymous, no chroot)
  guild-clock      10.10.5.30  NTP server (no NTP auth, time manipulation)
  city-directory   10.10.5.31  DNS forwarder (open recursion, DNSSEC off)
  scribes-post     10.10.5.32  Syslog relay (UDP 514, no TLS)
```

## Step 1, jump-host to attacker machine [x]

Remove enterprise NIC. Add attacker tooling.

- `orchestrator/ctf-config.yaml`: remove `jump_host.ip` (enterprise IP)
- `infrastructure/jump-host/Dockerfile`: add smbclient, hydra, tcpdump, socat, ftp;
  Python venv at `/opt/attacker-env` with pymodbus, paramiko, impacket
- `orchestrator/generate.py`: `generate_jump_host_compose()`: remove ent_net
- `orchestrator/adversary-readme.txt`: remove "reach enterprise directly"; list tools
- `infrastructure/jump-host/entrypoint.sh`: plant `~/loot/prior-recon.txt` (referencing
  10.10.0.10) in each adversary home dir
- `tests/unit/test_generate.py`: fix `test_generate_jump_host_compose`
- `tests/integration/test_artifacts.py`: remove 10.10.1.5 assertion

Verify: `ssh ponder@localhost -p 2222`, then from ponders-machine `ping 10.10.1.10` is expected to fail.

## Step 2, admin@home machine (rincewind-home) [x]

New dual-homed container. Three independent compromise paths.

Three attack paths (all active simultaneously):
1. SSH brute force: `rincewind` / `wizzard`
2. OSINT: `~/loot/prior-recon.txt` on jump-host references 10.10.0.10
3. HTTP :80 Flask `/status` endpoint, default auth `admin:admin`

Loot (found after any compromise):
- `~/.vpn/uupl-vpn.conf`: WireGuard config (cosmetic; shows AllowedIPs for enterprise + ops)
- `~/.ssh-keys/uupl_eng_key`: Ed25519 private key → `engineer@10.10.2.30`
- `~/notes.txt`: enterprise IPs, historian URL, SCADA URL

### New files
- `infrastructure/admin-home/Dockerfile`: debian:bookworm-slim, SSH+Flask, weak creds
- `infrastructure/admin-home/entrypoint.sh`
- `infrastructure/admin-home/app/status.py`: Flask `/status` endpoint
- `infrastructure/admin-home/loot/vpn/uupl-vpn.conf`
- `infrastructure/admin-home/loot/vpn/README.txt`
- `infrastructure/admin-home/loot/ssh/uupl_eng_key` (pre-generated Ed25519 keypair)
- `infrastructure/admin-home/loot/ssh/uupl_eng_key.pub`
- `infrastructure/admin-home/loot/notes.txt`

### Changes to existing files
- `orchestrator/ctf-config.yaml`: add `internet_zone.admin_home` section
- `orchestrator/generate.py`:
  - add `"admin-home": INFRA_DIR / "admin-home"` to COMPONENT_DIRS
  - add `generate_internet_zone_compose()` → `zones/internet/docker-compose.yml`
  - update `generate_firewall_sh()` addrs dict: `"admin_home_ip"` from config
  - update `main()` to call new generator
- `orchestrator/firewall-rules.txt`: add `{admin_home_ip}` ACCEPT before
  internet→enterprise DROP
- `Makefile`: add `zones/internet/docker-compose.yml` to up/down/clean/purge
- `zones/operational/components/engineering-workstation/entrypoint.sh`: append
  `uupl_eng_key.pub` to `engineer`'s authorized_keys

Verify:
```bash
nmap 10.10.0.10                              # find :22 and :80
curl -u admin:admin http://10.10.0.10/status # HTTP path
ssh rincewind@10.10.0.10                     # SSH (password: wizzard)
ssh -i ~/.ssh-keys/uupl_eng_key engineer@10.10.2.30  # key works
# Jump-host still blocked from enterprise:
nc -zv 10.10.1.10 22   # fails from 10.10.0.5
# Admin-home reaches enterprise:
nc -zv 10.10.1.10 22   # succeeds from 10.10.0.10
```

## Step 3a, Mosquitto broker [x]

New `eclipse-mosquitto:2.0` container at 10.10.3.60. `allow_anonymous true`.
Turbine PLC and IED relays publish telemetry/trip events via MQTT.

### New files
- `zones/control/components/mosquitto-broker/Dockerfile`
- `zones/control/components/mosquitto-broker/mosquitto.conf`

### Changes
- `orchestrator/ctf-config.yaml`: add `mosquitto_broker` device (10.10.3.60)
- `orchestrator/generate.py`: add `"mosquitto-broker"` to COMPONENT_DIRS
- `zones/control/components/turbine-plc/Dockerfile`: add paho-mqtt
- `zones/control/components/turbine-plc/plc_server.py`: add `mqtt_publish_loop()`
  publishing to `uupl/turbine/telemetry` every 5s
- `zones/control/components/ied-relay/Dockerfile`: add paho-mqtt
- `zones/control/components/ied-relay/relay_server.py`: publish to
  `uupl/relay/{RELAY_ID}/trip` on trip event
- `orchestrator/ctf-config.yaml`: add `MQTT_BROKER_IP: "10.10.3.60"` env to
  turbine_plc and ied_relay_a/b

Verify:
```bash
mosquitto_sub -h 10.10.3.60 -t "uupl/#" -v   # see live telemetry
```

## Step 3b, iotechsys/pymodbus-sim for actuators [x]

Replace custom Python actuator containers with `iotechsys/pymodbus-sim:1.0.6-x86_64`.
Standalone: does not require Edge Central/XRT. Default port 5020 overridden to 502.

### New files
- `zones/control/components/actuator-modbus-sim/Dockerfile`
- `zones/control/components/actuator-modbus-sim/entrypoint.sh`: selects profile/script by ACTUATOR_TYPE
- `zones/control/components/actuator-modbus-sim/configs/valve-profile.json`: HOLDING_REGISTERS addr 0
- `zones/control/components/actuator-modbus-sim/configs/pump-profile.json`: HOLDING_REGISTERS addr 0
- `zones/control/components/actuator-modbus-sim/configs/breaker-profile.json`: COILS addrs 0/1/2
- `zones/control/components/actuator-modbus-sim/scripts/breaker-logic.py`: trip/close → state; starts closed

### Register maps
| Device | Table | Addr | R/W | Meaning |
|--------|-------|------|-----|---------|
| fuel_valve, cooling_pump | HOLDING_REGISTERS | 0 | R/W | position/speed 0–100 (PLC writes) |
| breaker_a, breaker_b | COILS | 0 | R/W | state: 1=closed, 0=open (PLC polls) |
| breaker_a, breaker_b | COILS | 1 | W | trip command: write 1 to open (IED writes) |
| breaker_a, breaker_b | COILS | 2 | W | close command: write 1 to close (IED writes) |

### Changes
- `orchestrator/ctf-config.yaml`: all four actuators changed to `implementation: actuator-modbus-sim`
- `orchestrator/generate.py`: `"actuator-modbus-sim"` added to COMPONENT_DIRS

## Step 3c, Scada-LTS and stunnel-gateway [x]

FUXA was rejected: it is a visualisation dashboard only, not a SCADA system, and
cannot carry designed vulnerabilities. Replaced with two components:

Scada-LTS (`scadalts/scadalts`) replaces `distribution-scada` at 10.10.2.20 in
ics_operational (L3 site operations). Real SCADA/HMI system (Mango Automation base)
with real CVEs: Groovy script injection, SQL injection, unauthenticated endpoints.
Default credentials: admin/admin. Backed by a MySQL sidecar (scada-db at 10.10.2.19,
credentials scadalts/scada2015). Runs a stunnel client that wraps outbound Modbus in
TLS for the gateway.

stunnel-gateway (`dweomer/stunnel`) is a new dual-homed container at
10.10.2.50 (ics_operational) / 10.10.3.50 (ics_control). It terminates TLS from
Scada-LTS, requires mutual TLS (client cert), and forwards plain Modbus to
turbine_plc:502. Misconfigured: TLSv1 pinned (HEX-3887), cert overdue for renewal
(HEX-4421). Client key on Scada-LTS is world-readable (HEX-5103).

Attack chain:
1. Compromise Scada-LTS via admin/admin or CVE
2. `cat /run/stunnel-certs/client.key` (chmod 644: HEX-5103)
3. `openssl s_client -connect 10.10.2.50:8502 -cert client.crt -key client.key`
4. Send Modbus writes through the TLS tunnel → direct PLC register access

Why Scada-LTS is in ics_operational (not control): the stunnel-gateway attack chain
only works if Scada-LTS is across a firewall boundary from the PLCs. An attacker
already in ics_control can reach PLCs directly on :502; the cert theft path is
only meaningful from ics_operational where direct Modbus to ics_control is firewalled.

TLS certs: generated by `generate.py` into gitignored `certs/` directory.
Volume-mounted into containers at runtime. Never committed to the repo.

### New files
- `zones/control/components/stunnel-gateway/`: `dweomer/stunnel` image, TLS server config
- `zones/operational/components/scada-lts/`: ops Scada-LTS (HTTP→historian data source)
- `zones/control/components/scada-lts-ctrl/`: control Scada-LTS (Modbus→PLC via stunnel)

### Changes
- `orchestrator/ctf-config.yaml`: `scada_server.implementation: scada-lts`;
  `hmi_main.implementation: scada-lts-ctrl`; add `stunnel_gateway` block
- `orchestrator/generate.py`: `generate_certs()` for TLS; MySQL sidecars in both
  operational and control compose generators; stunnel-gateway dual-homed service
- `.gitignore`: `certs/` (generated at `./ctl generate` time, never committed)

### Note on scada-server/
`zones/operational/components/scada-server/` is kept but not wired into any config.
Its designed Flask vulnerabilities (credential chain, `/config` dump, historian SQLi
pivot) are preserved for potential future use or a separate scenario.

### Two-SCADA architecture
| Instance | Zone | Role | Data source | Write? |
|----------|------|------|-------------|--------|
| `distribution-scada` (10.10.2.20) | ics_operational | Operations SCADA: observe and report | HTTP → historian | No |
| `uupl-hmi` (10.10.3.10) | ics_control | Control SCADA/HMI: operate the plant | Modbus via stunnel → PLC | Yes |

Both run `scadalts/scadalts`, default creds `admin/admin`, Mango-base CVEs.
Control instance connects via stunnel client → `uupl-modbus-gw`:8502 → turbine PLC:502.
Cert theft chain: compromise control Scada-LTS → read world-readable `client.key`
→ send arbitrary Modbus writes direct to PLC, bypassing Scada-LTS access controls.

## Step 3d, sidecar support (OPC-UA and IEC-104) [ ]

Extend `generate_control_compose()` to support `sidecars` list per device.
OPC-UA and IEC-104 sidecars share the parent's network namespace
(`network_mode: service:<parent>`): reachable on parent's IP, different port.

### Changes to generate.py
After building main service, iterate `dev.get("sidecars", [])`:
- If sidecar has `ip`: own network entry (independently addressable)
- If no `ip`: `network_mode: service:<parent>` + `depends_on: [parent]`

### New implementation dirs (TBD, confirm images first)
- `zones/control/components/opcua-sidecar/`: thin-edge or python-opcua bridge
- `zones/control/components/iec104-sidecar/`: RichyP7 or equivalent

OPC-UA: reads Modbus from `127.0.0.1:502`, serves `opc.tcp://10.10.3.21:4840`,
SecurityMode=None.

IEC-104: maps same registers as Modbus, auth "not started".

## Deferred, routers and DMZ

Per-zone router containers and a DMZ with internet-facing vulnerable services.
Does NOT affect anything above: subnets and Docker networks are unchanged.
Implement after this phase is stable.

## Sequence summary

```
Step 1  →  Step 2          (internet zone, in order)
Step 3a →  Step 3b  →  Step 3c  →  Step 3d   (control zone, in order)

Steps 1+2 and steps 3a–3d can run in parallel with each other.
```

# Phase 2, DMZ Attack Zone

## Overview

The DMZ sits between `ics_internet` and `ics_enterprise`. Not a secure DMZ, a vulnerability-rich testbed. Attackers pivot through it on their way inward.
Its devices are interesting targets in their own right AND relay infrastructure
for the deeper zones.

New network: `ics_dmz` at `10.10.5.0/24`.

Firewall policy:
- `ics_internet` → `ics_dmz`: permitted (attack surface)
- `ics_dmz` → `ics_enterprise`: selectively permitted (simulates DMZ→internal access)
- `ics_dmz` → `ics_operational`: selectively permitted (historian, SCADA)
- `ics_internet` → `ics_enterprise`: still blocked directly (existing rule unchanged)

Discworld theming: the Guild Quarter, the boundary area between Unseen
University and Ankh-Morpork proper, where commercial and institutional
interfaces happen.

## Device inventory

### Priority 1, OT data brokers

| Device | Hostname | IP | Image | Vulnerability |
|--------|----------|----|-------|---------------|
| umati-gateway | `guild-exchange` | 10.10.5.10 | umati/umati-gateway (pre-fix commit) | CVE-2025-27615: web UI :8080, no auth, OPC UA↔MQTT bridge config r/w |
| neuron-gateway | `sorting-office` | 10.10.5.11 | `emqx/neuron:2.11.5` | Default creds `admin`/`0000`, no TLS, Modbus south device bridges to turbine_plc |
| mqtt-dmz | `clacks-relay` | 10.10.5.12 | `eclipse-mosquitto:2.0.22` | `allow_anonymous true`, port 1883, no TLS |
| opcua-server | `guild-register` | 10.10.5.13 | `ghcr.io/thin-edge/opc-ua-demo-server:0.0.8` | Anonymous auth, SecurityMode=None; callable methods: startPump, stopPump, resetFilter |
| iec104-rtu | `substation-rtu` | 10.10.5.14 | `ghcr.io/richyp7/iec60870-5-104-simulator:v0.1.7` | No-auth REST API :8080: reconfigure datapoints on the fly |

umatiGateway: pin to commit before `5d81a34` (the fix). UI exposes full OPC UA → MQTT
bridge config with no auth: attacker reads/modifies which PLC tags flow to which topics.

Neuron attack chain: `ponders-machine` → `sorting-office:7000` (admin/0000) → add
Modbus south device pointing at `turbine_plc (10.10.3.21:502)` → read/write PLC registers
through the gateway without touching the control zone directly.

### Priority 2, remote access (pivot infrastructure)

| Device | Hostname | IP | Image | Vulnerability |
|--------|----------|----|-------|---------------|
| ssh-bastion | `contractors-gate` | 10.10.5.20 | `debian:12.0`, OpenSSH 9.2p1-2 | CVE-2024-6387 (regreSSHion): unauthenticated RCE; also `PermitRootLogin yes`, root/`uupl2015` |
| sftp-drop | `dispatch-box` | 10.10.5.21 | `atmoz/sftp:debian` | Anonymous write to `/upload`, directory traversal via `../` |

ssh-bastion: pin `openssh-server=1:9.2p1-2+deb12u4` from snapshot.debian.org.
`AllowAgentForwarding yes` for socket hijacking. Simulates vendor contractor SSH bastion.

### Priority 3, supporting infrastructure (amplifier attacks)

| Device | Hostname | IP | Image | Vulnerability |
|--------|----------|----|-------|---------------|
| ntp-server | `guild-clock` | 10.10.5.30 | `cturra/ntp@sha256:7224d4e7c7833aabbcb7dd70c46c8a8dcccda365314c6db047b9b10403ace3bc` | No NTP auth (ntpq/ntpdc open): time manipulation disrupts cert validation and log timestamps |
| dns-forwarder | `city-directory` | 10.10.5.31 | `ubuntu/bind9:9.20-26.04_edge` | DNSSEC disabled, open recursive resolver: cache poisoning possible |
| syslog-relay | `scribes-post` | 10.10.5.32 | `balabit/syslog-ng:4.11.0` | UDP 514 plaintext, no TLS: sniff monitoring, spoof logs |

## Attack chains

Chain A, data broker pivot (OT-specific):
`ponders-machine` → `sorting-office:7000` (admin/0000) → add Modbus south endpoint
→ `turbine_plc:502` → read/write PLC registers through gateway

Chain B, umatiGateway config theft and OPC-UA pump sabotage:
`ponders-machine` → `guild-exchange:8080` (no auth, CVE-2025-27615) → read OPC UA
server list → find `guild-register:4840` → browse pump object tree → call `stopPump()`
method (thin-edge demo server: anonymous, SecurityMode=None, methods directly callable)

Chain F, IEC-104 datapoint manipulation:
`ponders-machine` → `substation-rtu:8080` (no-auth REST API) → reconfigure datapoint
values → false readings appear in control room → operator mis-response during incident

Chain C, SSH bastion RCE:
`ponders-machine` → `contractors-gate:22` → trigger regreSSHion (CVE-2024-6387)
→ root shell on bastion → pivot into enterprise zone (bastion has enterprise NIC)

Chain D, DNS poisoning and credential harvest:
`ponders-machine` → compromise `city-directory` DNS → poison `uupl-historian`
→ MITM historian traffic → harvest credentials → lateral move to operational zone

Chain E, time manipulation:
`ponders-machine` → `guild-clock:123` (ntpq, no auth) → manipulate system time
→ relay protection timestamp mismatches → engineer confusion during incident response

## Implementation notes

### New files required
- `orchestrator/ctf-config.yaml`: add `dmz` to networks; add `dmz_zone` section
- `orchestrator/generate.py`: add `generate_dmz_compose()`; add DMZ COMPONENT_DIRS entries; add DMZ firewall rules to `generate_firewall_sh()`
- `orchestrator/firewall-rules.txt`: DMZ rules block
- `zones/dmz/components/umati-gateway/`: clone pre-fix commit, custom Dockerfile
- `zones/dmz/components/neuron-gateway/`: emqx/neuron, Dockerfile + config
- `zones/dmz/components/mqtt-dmz/`: eclipse-mosquitto:2.0, mosquitto.conf
- `zones/dmz/components/opcua-server/`: Dockerfile
- `zones/dmz/components/ssh-bastion/`: Dockerfile pinning OpenSSH 9.2
- `zones/dmz/components/sftp-drop/`: atmoz/sftp, config
- `zones/dmz/components/ntp-server/`: Dockerfile + ntp.conf (noquery off)
- `zones/dmz/components/dns-forwarder/`: Dockerfile + named.conf (allow-recursion any)
- `zones/dmz/components/syslog-relay/`: Dockerfile + syslog-ng.conf

### COMPONENT_DIRS additions
```python
"umati-gateway":    ZONES_DIR / "dmz" / "components" / "umati-gateway",
"neuron-gateway":   ZONES_DIR / "dmz" / "components" / "neuron-gateway",
"mqtt-dmz":         ZONES_DIR / "dmz" / "components" / "mqtt-dmz",
"opcua-server":     ZONES_DIR / "dmz" / "components" / "opcua-server",
"iec104-rtu":       ZONES_DIR / "dmz" / "components" / "iec104-rtu",
"ssh-bastion-vuln": ZONES_DIR / "dmz" / "components" / "ssh-bastion",
"sftp-drop":        ZONES_DIR / "dmz" / "components" / "sftp-drop",
"ntp-server":       ZONES_DIR / "dmz" / "components" / "ntp-server",
"dns-forwarder":    ZONES_DIR / "dmz" / "components" / "dns-forwarder",
"syslog-relay":     ZONES_DIR / "dmz" / "components" / "syslog-relay",
```

### Prerequisite, verify umatiGateway image
```bash
# Find the last vulnerable commit (before 5d81a34)
git clone https://github.com/umati/umati-gateway
git log --oneline 5d81a34~1 | head -5
```

Phase 2 is complete.
