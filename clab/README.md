# clab/

Containerlab artefacts. The lab runs on clab end-to-end. Every zone has a
topology under `clab/<zone>-zone.clab.yaml`; every router runs from the
shared `clab/frr/` image; the per-zone `zones/*/docker-compose.yml` files
stay around as the build tool for application images and nothing more.

## Why

The previous fabric was Docker bridges plus alpine + iptables router
containers. It worked, but visitors only ever met a Linux firewall behind
each zone boundary. Containerlab plus FRR gives:

- a real router admin plane (`vtysh`, ACL syntax, routing-protocol
  configuration) that visitors can compromise alongside the application
  plane
- declarative topology in YAML, links as first-class objects
- the start of an OT-realistic L2/L3 layer where attacks like ARP
  poisoning, STP root takeover, OSPF / BGP misconfiguration, and SNMP
  write-community abuse become viable

## What is here

```
clab/
  control-zone.clab.yaml       topology for the control zone
  dmz-zone.clab.yaml           topology for the dmz zone
  internet-zone.clab.yaml      topology for the internet zone (no router)
  enterprise-zone.clab.yaml    topology for the enterprise zone
  operational-zone.clab.yaml   topology for the operational zone
  frr/
    Dockerfile                 FRR + iptables + openssh + vtysh-shell admin
                               (image tag: clab-router, reused by every router)
    daemons                    enabled FRR daemons (zebra + staticd)
    ops-ctrl-fw.frr.conf       control-zone gateway config
    inet-dmz-fw.frr.conf       internet-side dmz boundary config
    dmz-ent-fw.frr.conf        enterprise-side dmz boundary config
    ent-ops-fw.frr.conf        enterprise-operational boundary config
    ops-wan-router.frr.conf    operational-wan boundary config
    sshd_config                admin-plane sshd config
    start.sh                   startup wrapper: iptables, sshd, then FRR
  README.md                    this file
```

Every topology sets `prefix: ""` so docker container names match what
compose's `container_name` produced. `docker exec hex-turbine-plc ...` works
the same as it always did; tests and runbooks stay fabric-agnostic.

## Network addressing

Authoritative IP plan, mirrored across the per-zone clab topologies:

```
ics_internet (10.10.0.0/24)     public / city network (Purdue: external)
  unseen-gate       10.10.0.5   attacker machine (SSH entry point)
  wizzards-retreat  10.10.0.10  admin@home, triple-homed (simulates VPN)
  inet-dmz-fw       10.10.0.200 internet/dmz boundary router

ics_enterprise (10.10.1.0/24)   corporate IT (Purdue L4)
  wizzards-retreat  10.10.1.3   second NIC (VPN tunnel endpoint)
  hex-legacy-1      10.10.1.10  legacy workstation
  bursar-desk       10.10.1.20  enterprise workstation (also on ops: 10.10.2.100)
  contractors-gate  10.10.1.30  ssh bastion (also on dmz: 10.10.5.20)
  dmz-ent-fw        10.10.1.201 dmz/enterprise boundary router
  ent-ops-fw        10.10.1.202 enterprise/operational boundary router

ics_operational (10.10.2.0/24)  site operations management (Purdue L3)
  uupl-historian     10.10.2.10  process uupl-historian (SQLite, time-series)
  scada-db           10.10.2.19  MySQL backing DB for operations Scada-LTS
  distribution-scada 10.10.2.20  Scada-LTS, operations SCADA (admin/admin)
  uupl-eng-ws        10.10.2.30  engineering workstation (also on control)
  uupl-modbus-gw     10.10.2.50  stunnel TLS gateway, ops NIC
  wizzards-retreat   10.10.2.3   admin@home third NIC
  bursar-desk        10.10.2.100 enterprise workstation second NIC
  ent-ops-fw         10.10.2.202 enterprise/operational boundary router
  ops-ctrl-fw        10.10.2.203 operational/control boundary router
  ops-wan-router     10.10.2.204 operational/wan boundary router

ics_control (10.10.3.0/24)      area supervisory + field (Purdue L1-2)
  uupl-hmi           10.10.3.10  FUXA 1.1.7 control HMI (CVE-2023-32545/6/7, :1881)
  hex-turbine-plc    10.10.3.21  turbine PLC (Modbus :502, OPC-UA :4840, MQTT)
  uupl-relay-a       10.10.3.31  protective relay IED, Dolly Sisters feeder
  uupl-relay-b       10.10.3.32  protective relay IED, Nap Hill feeder
  uupl-meter         10.10.3.33  revenue meter IED
  uupl-modbus-gw     10.10.3.50  stunnel TLS gateway, ctrl NIC
  uupl-fuel-valve    10.10.3.51  custom pymodbus actuator (HR: valve position)
  uupl-cooling-pump  10.10.3.52  custom pymodbus actuator (HR: pump speed)
  uupl-breaker-a     10.10.3.53  custom pymodbus actuator (COILS, Dolly Sisters)
  uupl-breaker-b     10.10.3.54  custom pymodbus actuator (COILS, Nap Hill)
  uupl-mqtt          10.10.3.60  Mosquitto (allow_anonymous, uupl/# topics)
  uupl-eng-ws        10.10.3.100 engineering workstation second NIC
  ops-ctrl-fw        10.10.3.203 operational/control boundary router

ics_wan (10.10.4.0/24)          OT/RTU WAN (placeholder)
  ops-wan-router    10.10.4.204  operational/wan boundary router

ics_dmz (10.10.5.0/24)          Guild Quarter, externally-reachable attack surface
  guild-exchange     10.10.5.10  umatiGateway (CVE-2025-27615, no auth UI :8080)
  sorting-office     10.10.5.11  Neuron protocol gateway (admin/uupl2015, :7000)
  clacks-relay       10.10.5.12  MQTT broker (allow_anonymous, :1883)
  guild-register     10.10.5.13  OPC-UA server (anonymous, SecurityMode=None, :4840)
  substation-rtu     10.10.5.14  IEC-104 RTU (no-auth REST :8080, IEC-104 :2404)
  contractors-gate   10.10.5.20  SSH bastion (CVE-2024-6387, root/uupl2015)
  dispatch-box       10.10.5.21  SFTP drop (anonymous/anonymous, no chroot)
  guild-clock        10.10.5.30  NTP server (no NTP auth)
  city-directory     10.10.5.31  DNS forwarder (open recursion, DNSSEC off)
  scribes-post       10.10.5.32  Syslog relay (UDP 514, no TLS, no source auth)
  inet-dmz-fw        10.10.5.200 internet/dmz boundary router
  dmz-ent-fw         10.10.5.201 dmz/enterprise boundary router
```

## Running the lab

```bash
./ctl up      # builds images, deploys topologies, runs cross-zone attaches
./ctl down    # destroys topologies, removes the cross-attaches and bridges
./ctl ssh     # ssh into unseen-gate as ponder
```

`./ctl up` calls `orchestrator/generate.py` which writes
`infrastructure/clab-up.sh` and `infrastructure/clab-down.sh`. Those two
scripts pre-create the six host Linux bridges with `sudo ip link add`
(one prompt per session), build the `clab-router` and `lab-mysql8`
images, then `containerlab deploy` each per-zone topology. Each
topology declares its bridges as `kind: bridge` nodes and connects
every container via explicit veth `links:`. There is no
`docker network connect` matrix any more; cross-zone connectivity is
modelled in the topology files themselves.

## What changes for visitors

Every zone gateway is FRR for routing plus iptables for packet filter,
with an admin plane on TCP/22. SSH to the gateway IP as `admin` / `admin`
and the visitor lands directly in `vtysh`. `enable` (password
`uupl-router`) opens `configure terminal` and the static routes plus
interface config become editable. The iptables policy is loaded from
`infrastructure/routers/generated/<router>-acl.sh`, deny-by-default
forwarding unchanged. Realism is in the admin plane: vendor defaults
that nobody changed since commissioning.

The five gateways:

- `inet-dmz-fw` at `10.10.5.200` and `10.10.0.200` (internet/dmz)
- `dmz-ent-fw` at `10.10.5.201` and `10.10.1.201` (dmz/enterprise)
- `ent-ops-fw` at `10.10.1.202` and `10.10.2.202` (enterprise/operational)
- `ops-ctrl-fw` at `10.10.3.203` and `10.10.2.203` (operational/control)
- `ops-wan-router` at `10.10.2.204` and `10.10.4.204` (operational/wan)

## Known gaps

1. No L2/L3 protocol attack surface yet (ARP poisoning, STP, OSPF/BGP
   misconfig). The router admin plane is in; protocol-attack surface
   lands in subsequent commits. The kind:bridge fabric makes the L2
   surface real (real Linux bridges, real ARP, real STP behaviour),
   but no attack tooling targets it yet.
2. The wan zone (`ics_wan` 10.10.4.0/24) is a placeholder bridge. The
   `ops-wan-router` boundary works; there is nothing on the wan side
   to talk to.

## Verifying

The Phase 1, 2, and 3 smoke tests are the acceptance suite:

```bash
bash tests/smoke/test_phase1.sh
bash tests/smoke/test_phase2.sh
bash tests/smoke/test_phase3.sh
bash tests/smoke/test_phase4.sh
bash tests/smoke/test_phase5.sh
```
