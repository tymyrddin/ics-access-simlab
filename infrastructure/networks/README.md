# Shared zone networks

The `docker-compose.yml` in this directory is *generated* by the orchestrator.
It must exist before any zone stack can start, because all zone stacks declare
their networks as `external`.

## Generate it

```bash
python orchestrator/generate.py [orchestrator/ctf-config.yaml]
```

## Network topology

```
ics_internet (10.10.0.0/24)     — public / city network (Purdue: external)
  unseen-gate       10.10.0.5   attacker machine (SSH entry point for participants)
  wizzards-retreat  10.10.0.10  admin@home, dual-homed into enterprise (simulates VPN)

ics_enterprise (10.10.1.0/24)   — corporate IT (Purdue L4)
  wizzards-retreat  10.10.1.3   second NIC ("VPN tunnel" endpoint)
  hex-legacy-1      10.10.1.10  legacy workstation
  bursar-desk       10.10.1.20  enterprise workstation (also on ops: 10.10.2.100)

ics_operational (10.10.2.0/24)  — site operations management (Purdue L3)
  uupl-historian     10.10.2.10  process historian (SQLite, time-series data)
  scada-db           10.10.2.19  MySQL backing DB for operations Scada-LTS
  distribution-scada 10.10.2.20  Scada-LTS — operations SCADA (read/observe, admin/admin)
  uupl-eng-ws        10.10.2.30  engineering workstation (also on control: 10.10.3.100)
  uupl-modbus-gw     10.10.2.50  stunnel TLS gateway — ops NIC (also on control: 10.10.3.50)

ics_control (10.10.3.0/24)      — area supervisory + field devices (Purdue L1-2)
  hmi_main-db        10.10.3.11  MySQL backing DB for control Scada-LTS
  uupl-hmi           10.10.3.10  Scada-LTS — control SCADA/HMI (read+write, admin/admin)
  uupl-modbus-gw     10.10.3.50  stunnel TLS gateway — ctrl NIC (forwards :8502 → PLC :502)
  hex-turbine-plc    10.10.3.21  turbine PLC (Modbus :502, MQTT publish)
  uupl-relay-a       10.10.3.31  protective relay IED — Dolly Sisters feeder
  uupl-relay-b       10.10.3.32  protective relay IED — Nap Hill feeder
  uupl-meter         10.10.3.33  revenue meter IED
  uupl-fuel-valve    10.10.3.51  pymodbus-sim actuator (HOLDING_REGISTERS: valve position)
  uupl-cooling-pump  10.10.3.52  pymodbus-sim actuator (HOLDING_REGISTERS: pump speed)
  uupl-breaker-a     10.10.3.53  pymodbus-sim actuator (COILS: state/trip/close — Dolly Sisters)
  uupl-breaker-b     10.10.3.54  pymodbus-sim actuator (COILS: state/trip/close — Nap Hill)
  uupl-mqtt          10.10.3.60  Mosquitto broker (allow_anonymous, uupl/# topics)

ics_dmz (10.10.5.0/24)         — Guild Quarter: externally-reachable attack surface
  guild-exchange     10.10.5.10  umatiGateway (CVE-2025-27615, no auth on management UI :8080)
  sorting-office     10.10.5.11  Neuron protocol gateway (admin/0000, Modbus bridge :7000)
  clacks-relay       10.10.5.12  MQTT broker (allow_anonymous, port 1883)
  guild-register     10.10.5.13  OPC-UA server (anonymous auth, SecurityMode=None, :4840)
  substation-rtu     10.10.5.14  IEC-104 RTU (no-auth REST API :8080, IEC-104 :2404)
  contractors-gate   10.10.5.20  SSH bastion (CVE-2024-6387, PermitRootLogin yes, root/uupl2015)
                     10.10.1.30  second NIC in enterprise (pivot path)
  dispatch-box       10.10.5.21  SFTP drop (anonymous/anonymous, no chroot jail)
  guild-clock        10.10.5.30  NTP server (no NTP auth, open to time manipulation)
  city-directory     10.10.5.31  DNS forwarder (open recursion, DNSSEC validation off)
  scribes-post       10.10.5.32  Syslog relay (UDP 514, no TLS, no source authentication)
```

## Startup order

Networks must be created before zone stacks start.
`start.sh` (also generated) handles this in the correct order:

```
infrastructure/networks/docker-compose.yml   up -d   ← first
zones/enterprise/docker-compose.yml          up -d
zones/operational/docker-compose.yml         up -d
zones/control/docker-compose.yml             up -d   ← last
```

