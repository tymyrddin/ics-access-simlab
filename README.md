# ICS-SimLab

A multi-zone Industrial Control System simulation built for realistic red team exercises and CTF scenarios. The
environment models the operational infrastructure of Unseen University Power & Light Co., Ankh-Morpork's primary
utility provider with an infrastructure assembled over decades, documentation patchy, cybersecurity posture: emergent.

Four network zones (internet, enterprise, operational, control) are separated by deliberate, exploitable boundaries.
Vulnerabilities are properties of the simulated systems, not configuration options. Consequences emerge from what
players actually do.

A top-level YAML config selects the topology and component variants. A code generator produces all Docker Compose
stacks from this config. The environment runs on a single Linux host.

## Dependencies

Linux only. Docker's fixed-IP bridge networking requires Linux. Docker Desktop on macOS/Windows uses a VM and
the zone topology will not behave as designed.

| Dependency     | Version     | Notes                                                      |
|----------------|-------------|------------------------------------------------------------|
| Linux          | kernel 5.x+ | Ubuntu 22.04 / Debian 12 tested                            |
| Docker Engine  | 24+         | Not Docker Desktop                                         |
| Docker Compose | v2.20+      | Plugin (`docker compose`), not standalone `docker-compose` |
| Python         | 3.10+       | For the orchestrator                                       |
| PyYAML         | any recent  | `pip install pyyaml` or `apt install python3-yaml`         |

## Hardware

The full environment runs ~37 containers simultaneously.

| Resource | Minimum    | Recommended |
|----------|------------|-------------|
| RAM      | 4 GB       | 8 GB        |
| CPU      | 2 cores    | 4 cores     |
| Disk     | 10 GB free | 20 GB free  |

A Hetzner CX32 (4 vCPU / 8 GB) runs the full stack comfortably.

## Quickstart

```bash
./ctl up          # generate + start everything — prints SSH command when ready
./ctl firewall    # apply inter-zone firewall rules (sudo)
./ctl ssh         # drop into unseen-gate as ponder
./ctl verify      # print Step 2 verification commands
./ctl down        # stop everything
```

On first `./ctl up`, a dedicated ed25519 keypair (`lab-key` / `lab-key.pub`) is generated in the repo root and
registered for user `ponder`. Use `./ctl ssh [user]` to connect — it selects the lab key automatically, so
participants with many keys in their SSH agent won't hit authentication failures.

`lab-key` is gitignored. **On a shared or cloud host, restrict repo directory permissions** so other local users
cannot read it (`chmod 700 .` or equivalent).

### All `./ctl` commands

| Command            | What it does                                            |
|--------------------|---------------------------------------------------------|
| `./ctl up`         | Generate + start all zones, print SSH command           |
| `./ctl down`       | Stop and remove all containers                          |
| `./ctl ssh [user]` | SSH into unseen-gate (default user: `ponder`)           |
| `./ctl firewall`   | Apply inter-zone iptables rules (sudo)                  |
| `./ctl verify`     | Print verification commands for the current scenario    |
| `./ctl generate`   | Regenerate compose files without starting               |
| `./ctl clean`      | `down` + remove generated files                         |
| `./ctl purge`      | `clean` + remove all images + prune build cache         |

To use an alternate config:
```bash
CONFIG=orchestrator/configs/smart-grid.yaml ./ctl up
```

## Authentication modes

The attacker machine supports two auth modes, set via `auth_mode` in `ctf-config.yaml`:

| Mode | Use case | How it works |
|------|----------|--------------|
| `key` (default) | Self-hosted, Hetzner, local dev | Pubkey auth. Keys from `adversary-keys`. `./ctl ssh` selects the right key automatically. |
| `password` | Root-Me and platforms that publish connection strings | Password auth. Credentials set from `accounts:` in config, no key file needed. |

**Key mode** (default — local dev and Hetzner):
```yaml
jump_host:
  auth_mode: key
```
`./ctl up` generates a dedicated `lab-key` / `lab-key.pub` and registers it for `ponder`.
Connect with `./ctl ssh ponder`. For Hetzner, pre-populate `adversary-keys` with participant
public keys before deploying.

**Password mode** (Root-Me):
```yaml
jump_host:
  auth_mode: password
  accounts:
    ponder:   ponder
    hex:      hex
    ridcully: wizzard
    librarian: books
    dean:     dean
```
Credentials are published in the room info on the CTF platform:
```
ssh ponder@ctf01.root-me.org -p 22222   (password: ponder)
ssh hex@ctf01.root-me.org    -p 22222   (password: hex)
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

## Inter-zone firewall

`./ctl firewall` writes iptables rules to the host's `DOCKER-USER` chain after zones are up. This enforces
inter-zone routing policy. Skip it on a local dev machine if you don't need isolation.

On Hetzner, `setup.sh` adds a sudoers rule so the deploy user can run `firewall.sh` without a full root shell.

## Hetzner deployment

One-time host setup (run once as root on a fresh instance):
```bash
bash zones/internet/components/attacker-machine/setup.sh
```
This moves the host sshd to port 2222. Reconnect on 2222 for all future host admin.

Add participant keys before deploying:
```bash
# Create adversary-keys — one line per participant: username pubkey [comment]
# Valid usernames: ponder  hex  ridcully  librarian  dean
vi zones/internet/components/attacker-machine/adversary-keys
```

If `adversary-keys` is pre-populated, `./ctl up` will not overwrite it. Participants connect using their
own keys; `./ctl ssh` falls back to regular SSH when no `lab-key` is present.

Restrict repo directory permissions so the deploy user's private key is not world-readable:
```bash
chmod 700 /path/to/ics-simlab
```

Set SSH port to 22 in `ctf-config.yaml` (default is 2222 for local dev):
```yaml
jump_host:
  ssh_host_port: 22
```

Deploy:
```bash
./ctl up
sudo ./ctl firewall
```

Participant access (Hetzner):
```
ssh ponder@<hetzner-ip>
```

## Testing

```bash
# Unit tests — no Docker needed
pytest tests/unit/ -v

# Artefact tests — runs generate.py and checks all output files
pytest tests/integration/ -v

# Or both at once
make test
```

## Configuration

Edit `orchestrator/ctf-config.yaml` to change topology, addressing, or component variants, then run `./ctl up`.
Compose files are always regenerated from the config — don't edit them directly.

See [docs/architecture.md](docs/architecture.md) for the full system design and [PLAN.md](docs/PLAN.md) for the
current development roadmap.

## Thank you

This project was inspired by [Curtin ICS-SimLab](https://github.com/JaxsonBrownie/ICS-SimLab), a Docker-based ICS
simulation framework developed at Curtin University and presented at the First International Workshop on Secure
Industrial Control Systems and Industrial IoT (IEEE, 2025). The original work by J. Brown, D. S. Pham, S. Soh,
F. Motalebi, S. Eswaran, and M. Almashor demonstrated the core concept of containerised ICS environments with
Hardware-in-the-Loop physical process models.

This repository is a ground-up reimplementation: all containers, orchestration, network topology, vulnerability design,
and theming are original. No code from the original ICS-SimLab is included.
