# Development plan

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
  scada-db         10.10.2.19  MySQL sidecar for distribution-scada
  distribution-scada 10.10.2.20  Scada-LTS: operations SCADA (observe only)
  uupl-eng-ws      10.10.2.30 / 10.10.3.100
  uupl-modbus-gw   10.10.2.50 / 10.10.3.50  stunnel TLS gateway (dual-homed)

ics_control (10.10.3.0/24)                      area supervisory + field (Purdue L1-2)
  uupl-hmi         10.10.3.10  Scada-LTS: control HMI (read+write, admin/admin)
  hmi_main-db      10.10.3.11  MySQL sidecar for uupl-hmi
  hex-turbine-plc  10.10.3.21  turbine PLC (Modbus :502, MQTT publish)
  uupl-relay-a     10.10.3.31  protective relay IED: Dolly Sisters feeder
  uupl-relay-b     10.10.3.32  protective relay IED: Nap Hill feeder
  uupl-meter       10.10.3.33  revenue meter IED
  uupl-fuel-valve  10.10.3.51  actuator (Modbus, pymodbus-sim)
  uupl-cooling-pump 10.10.3.52 actuator (Modbus, pymodbus-sim)
  uupl-breaker-a   10.10.3.53  actuator (Modbus, pymodbus-sim)
  uupl-breaker-b   10.10.3.54  actuator (Modbus, pymodbus-sim)
  uupl-mqtt        10.10.3.60  Mosquitto broker (allow_anonymous)

ics_dmz (10.10.5.0/24)                          DMZ: Guild Quarter
  guild-exchange   10.10.5.10  umatiGateway (CVE-2025-27615, no auth on UI :8080)
  sorting-office   10.10.5.11  Neuron gateway (admin/0000, protocol bridge :7000)
  clacks-relay     10.10.5.12  MQTT broker (allow_anonymous, port 1883)
  guild-register   10.10.5.13  OPC-UA server (anonymous, SecurityMode=None, :4840)
  substation-rtu   10.10.5.14  IEC-104 RTU (no-auth REST API :8080, IEC-104 :2404)
  contractors-gate 10.10.5.20 / 10.10.1.30  SSH bastion (CVE-2024-6387, root/uupl2015)
  dispatch-box     10.10.5.21  SFTP drop (anonymous/anonymous, no chroot)
  guild-clock      10.10.5.30  NTP server (no NTP auth, time manipulation)
  city-directory   10.10.5.31  DNS forwarder (open recursion, DNSSEC off)
  scribes-post     10.10.5.32  syslog relay (UDP 514, no TLS)

ics_wan (10.10.4.0/24)                          OT/RTU network (city cellular, no VPN)
  (deferred: field devices zone)
```


## Status

### Internet zone

- Step 1 [x]: attacker machine (`unseen-gate`). No enterprise NIC. Tooling: smbclient, hydra, tcpdump, socat, ftp, pymodbus, paramiko, impacket. Loot planted in each adversary home dir.
- Step 2 [x]: admin@home (`wizzards-retreat`). Three compromise paths: SSH brute force (rincewind/wizzard), NFS anonymous mount (`/work`, world-readable, notes.txt), OSINT from prior-recon.txt. Loot on NFS: notes.txt. Full loot after SSH: VPN config, engineer SSH key, notes. NFS-Ganesha user-space NFSv3; container runs privileged for tmpfs staging (OverlayFS workaround).

### Control zone

- Step 3a [x]: Mosquitto broker at 10.10.3.60. allow_anonymous. Turbine PLC and IED relays publish telemetry via MQTT.
- Step 3b [x]: Actuators replaced with iotechsys/pymodbus-sim. Register map: fuel_valve and cooling_pump on HOLDING_REGISTERS[0]; breakers on COILS[0/1/2] (state/trip/close).
- Step 3c [x]: Scada-LTS replaces Flask SCADA and Flask HMI. Two instances: distribution-scada in ics_operational (observe only), uupl-hmi in ics_control (read+write). stunnel-gateway at 10.10.2.50/10.10.3.50: TLS from Scada-LTS, plain Modbus to PLC. Client key world-readable (HEX-5103). TLSv1 pinned (HEX-3887). Cert overdue (HEX-4421).
- Step 3d [x]: OPC-UA sidecar (`turbine_opcua`, `opc.tcp://10.10.3.21:4840`, SecurityMode None). IEC-104 was already in the PLC's own Python server on :2404 with live register data — no sidecar needed.

### DMZ zone

- Phase 2 [x]: All ten devices implemented and wired into generate.py. Firewall policy in place: internet open to DMZ; DMZ to enterprise via ssh-bastion only; DMZ to historian and SCADA web only; DMZ blocked from control and WAN.

### Pending

- Routers [ ]: Per-zone router containers. No impact on subnets or Docker networks. Add after current phase is stable and tested.
- Field devices zone [ ]: WAN zone (ics_wan 10.10.4.0/24). City RTUs, smart grid end devices, substation equipment. Deferred; per-vendor/per-firmware implementations when the time comes.

## Attack chains

### Phase 1: access and persistence

Entry via internet zone, pivot to enterprise, reach operational layer.

```
ponders-machine (10.10.0.5)
  → brute-force or OSINT → wizzards-retreat (10.10.0.10)
  → enterprise NIC (10.10.1.3) → hex-legacy-1 (10.10.1.10)
  → bursar-desk (10.10.1.20) → uupl-eng-ws (10.10.2.30)
  → historian (10.10.2.10) or distribution-scada (10.10.2.20)
  → steal stunnel client.key from Scada-LTS
  → direct Modbus to uupl-modbus-gw:8502 → turbine PLC registers
```

### Phase 2: DMZ pivot chains

Chain A, covert exfil via Neuron (multi-stage, requires prior inner-network foothold):
```
Phase 1 foothold → uupl-eng-ws (10.10.2.30) or uupl-modbus-gw (10.10.3.50)
  [control zone is reachable from here]
  → configure Neuron sorting-office:7000 (admin/uupl2015, password reused from bastion)
  → add Modbus south device pointing at turbine_plc:502
  → Neuron bridges PLC registers northbound to clacks-relay:1883 (MQTT, allow_anonymous)
  → attacker subscribes to clacks-relay from internet → reads live PLC telemetry
  [teaches: default-creds gateways in DMZ are dangerous even when firewalled —
   once inside, they become a persistent exfil pipeline out through the DMZ]
```

Chain B, umatiGateway config theft and pump sabotage:
```
ponders-machine → guild-exchange:8080 (no auth, CVE-2025-27615)
  → read OPC-UA server list → guild-register:4840
  → browse pump object tree → call stopPump() (SecurityMode=None, anon auth)
```

Chain C, SSH bastion RCE:
```
ponders-machine → contractors-gate:22
  → regreSSHion (CVE-2024-6387) → root shell
  → pivot to enterprise via bastion enterprise NIC (10.10.1.30)
```

Chain D, DNS poisoning:
```
ponders-machine → city-directory (open recursive resolver)
  → poison uupl-historian A record → MITM historian traffic → credential harvest
```

Chain E, time manipulation:
```
ponders-machine → guild-clock:123 (ntpq, no auth)
  → manipulate system time → relay protection timestamp mismatches
  → engineer confusion during incident response
```

Chain F, IEC-104 datapoint manipulation:
```
ponders-machine → substation-rtu:8080 (no-auth REST API)
  → reconfigure datapoint values → false readings in control room
  → operator mis-response during incident
```


## Routers

Per-zone router containers will provide realistic inter-zone routing behaviour. Subnets and Docker networks are unchanged; routers sit at zone boundaries and handle forwarding. Implementation deferred until current phase is stable and attack chains have been tested end-to-end.


## Stale artefacts

These directories are superseded and not wired into any config. Safe to delete once testing confirms nothing depends on them.

- `zones/control/components/actuator/`: original Python actuator, replaced by actuator-modbus-sim.
- `zones/control/components/hmi/`: original Flask HMI, replaced by scada-lts-ctrl.
- `zones/operational/components/scada-server/`: original Flask SCADA, replaced by scada-lts. Its designed vulnerabilities (credential chain, `/config` dump, historian SQLi pivot) are preserved here in case they are useful for a future scenario.