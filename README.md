# ICS access and persistence SimLab

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

The full environment runs ~35 containers simultaneously.

| Resource | Minimum    | Recommended |
|----------|------------|-------------|
| RAM      | 4 GB       | 8 GB        |
| CPU      | 2 cores    | 4 cores     |
| Disk     | 10 GB free | 20 GB free  |

A Hetzner CX32 (4 vCPU / 8 GB) runs the full stack comfortably.

## Quickstart

```bash
./ctl up          # generate + start everything, prints SSH command when ready
./ctl firewall    # apply inter-zone firewall rules (sudo)
./ctl ssh         # drop into unseen-gate as ponder
./ctl verify      # print Step 2 verification commands
./ctl down        # stop everything
```

On first `./ctl up`, a dedicated ed25519 keypair (`lab-key` / `lab-key.pub`) is generated in the repo root and
registered for user `ponder`. Use `./ctl ssh [user]` to connect: it selects the lab key automatically, so
participants with many keys in their SSH agent won't hit authentication failures.

`lab-key` is the operator key, never distributed to participants. For Hetzner deployments, run
`./ctl cohort-keys` to generate a separate participant keypair and distribute `cohort-key` to the cohort.

Both keypairs are gitignored. On a shared or cloud host, restrict repo directory permissions so other local
users cannot read them (`chmod 700 .` or equivalent).

### All `./ctl` commands

| Command                  | What it does                                            |
|--------------------------|---------------------------------------------------------|
| `./ctl up`               | Generate + start all zones, print SSH command           |
| `./ctl down`             | Stop and remove all containers                          |
| `./ctl ssh [user]`       | SSH into unseen-gate (default user: `ponder`)           |
| `./ctl cohort-keys`      | Generate a participant keypair for Hetzner deployments  |
| `./ctl firewall`         | Apply inter-zone iptables rules (sudo)                  |
| `./ctl verify`           | Print verification commands for the current scenario    |
| `./ctl generate`         | Regenerate compose files without starting               |
| `./ctl clean`            | `down` + remove generated files                         |
| `./ctl purge`            | `clean` + remove all images + prune build cache         |

To use an alternate config:
```bash
CONFIG=orchestrator/configs/smart-grid.yaml ./ctl up
```

## Authentication modes

The attacker machine supports two auth modes, set via `auth_mode` in `ctf-config.yaml`:

| Mode            | Use case                                              | How it works                                                                              |
|-----------------|-------------------------------------------------------|-------------------------------------------------------------------------------------------|
| `key` (default) | Self-hosted, Hetzner, local dev                       | Pubkey auth. Keys from `adversary-keys`. `./ctl ssh` selects the right key automatically. |
| `password`      | Root-Me and platforms that publish connection strings | Password auth. Credentials set from `accounts:` in config, no key file needed.            |

Key mode (default, local dev and Hetzner):
```yaml
attacker_machine:
  auth_mode: key
```
`./ctl up` generates a dedicated `lab-key` / `lab-key.pub` and registers it for `ponder` (operator access).
Connect with `./ctl ssh ponder`. For Hetzner, run `./ctl cohort-keys` to generate a separate participant
keypair and distribute `cohort-key` to the cohort before deploying.

Password mode (Root-Me):
```yaml
attacker_machine:
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

Six Docker networks, each mapped to a Purdue model layer:

| Network          | Subnet         | Zone                          |
|------------------|----------------|-------------------------------|
| `ics_internet`   | 10.10.0.0/24   | Internet / city network       |
| `ics_enterprise` | 10.10.1.0/24   | Corporate IT (Purdue L4)      |
| `ics_operational`| 10.10.2.0/24   | Site operations (Purdue L3)   |
| `ics_control`    | 10.10.3.0/24   | Area supervisory + field (L1-2)|
| `ics_dmz`        | 10.10.5.0/24   | DMZ: Guild Quarter            |
| `ics_wan`        | 10.10.4.0/24   | OT/RTU WAN (deferred)         |

Key dual-homed hosts: `wizzards-retreat` (internet + enterprise), `bursar-desk`
(enterprise + operational), `uupl-eng-ws` (operational + control),
`uupl-modbus-gw` (operational + control), `contractors-gate` (DMZ + enterprise).

See [infrastructure/networks/README.md](infrastructure/networks/README.md) for full addressing.

## Inter-zone routing

Zone isolation is enforced by five router containers, one per trust boundary. Each router is dual-homed
across two zone networks and applies iptables FORWARD rules within its own network namespace. No
host-level configuration is required; the lab enforces zone policy with or without `./ctl firewall`.

`./ctl firewall` applies the ICS_HIDE_GW chain, which hides Docker bridge gateway IPs (10.10.x.1) from
CTF containers so nmap scans inside the lab do not reveal host metadata. It adds realism but is not
required for correct routing or isolation.

On Hetzner, `setup.sh` adds a sudoers rule so the deploy user can run `firewall.sh` without a full root shell.

## Hetzner deployment

One-time host setup (run once as root on a fresh instance):
```bash
bash zones/internet/components/attacker-machine/setup.sh
```
This moves the host sshd to port 2222. Reconnect on 2222 for all future host admin.

Generate a participant keypair before deploying:
```bash
./ctl cohort-keys
```
This creates `cohort-key` / `cohort-key.pub` in the repo root and writes the public key into
`adversary-keys` for all five accounts. Distribute `cohort-key` (the private key) to participants
via the briefing doc or a secure channel. Running `./ctl cohort-keys` again generates a fresh
keypair and replaces the previous one cleanly, useful between cohorts.

Restrict repo directory permissions so the deploy user's private key is not world-readable:
```bash
chmod 700 /path/to/ics-access-simlab
```

Set SSH port to 22 in `ctf-config.yaml` (default is 2222 for local dev):
```yaml
attacker_machine:
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
# Unit tests, no Docker needed
pytest tests/unit/ -v

# Artefact tests, runs generate.py and checks all output files
pytest tests/integration/ -v

# Or both at once
make test
```

## Configuration

Edit `orchestrator/ctf-config.yaml` to change topology, addressing, or component variants, then run `./ctl up`.
Compose files are always regenerated from the config; don't edit them directly.

## Contributing

Contributions welcome:

- New device types (IEDs, PMUs, RTUs, relays)
- Protocol implementations
- Additional attack scenarios and CTF configs
- Security rules and detection logic
- Hardening variants for existing components

Before adding tests, read [tests/README.md](tests/README.md) for dependency ordering.
Respect the layering: *fix the architecture, not the test*.

## Disclaimer

This platform is for *authorised security research, education, and testing only*.
Use it to develop and validate PoCs in a safe environment before engaging with real systems
under proper authorisation.

The authors take no responsibility for misuse. If you're testing real ICS/SCADA systems,
make sure you have explicit written permission and understand the physical consequences.

## License and usage

This project is licensed under the [Polyform Noncommercial Licence](LICENSE).

You are welcome to use this software for:

- Learning and experimentation
- Academic or independent research
- Defensive security research
- Developing and validating proof-of-concepts
- Incident response exercises
- Non-commercial red/blue team simulations

You may not use this software for:

- Paid workshops or training
- Consultancy or advisory services
- Internal corporate training
- Commercial product development

If you want to use this project in a paid or commercial context, a commercial licence is required.
See [COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md) for details.

This project is actively developed and maintained to support realistic security research and training.
The licence ensures that:

- Security research remains accessible
- Defensive knowledge can spread
- Commercial exploitation is fair and sustainable

If you are unsure whether your use case is commercial, ask. [Ambiguity is solvable](https://tymyrddin.dev/contact/); silence is not.

## Acknowledgements

This project is built on the shoulders of a considerable pile of open source
work. Thank you to the authors and maintainers of:

SCADA and HMI:
[Scada-LTS](https://github.com/SCADA-LTS/Scada-LTS)

Protocol simulators and gateways:
[Neuron](https://github.com/emqx/neuron) (EMQ Technologies),
[umatiGateway](https://github.com/umati/umatiGateway) (umati community),
[opc-ua-demo-server](https://github.com/thin-edge/opc-ua-demo-server) (thin-edge.io),
[IEC 60870-5-104 Simulator](https://github.com/RichyP7/IEC60870-5-104-simulator) (RichyP7)

Messaging and transport:
[Eclipse Mosquitto](https://github.com/eclipse/mosquitto),
[stunnel](https://hub.docker.com/r/dweomer/stunnel) (dweomer image),
[BIND9](https://hub.docker.com/r/internetsystemsconsortium/bind9) (ISC official image),
[cturra/ntp](https://hub.docker.com/r/cturra/ntp),
[atmoz/sftp](https://github.com/atmoz/sftp),
[syslog-ng](https://github.com/syslog-ng/syslog-ng)

Actuator simulation:
[pymodbus-sim](https://hub.docker.com/r/iotechsys/pymodbus-sim) (IOTech Systems)

Python libraries:
[pymodbus](https://github.com/pymodbus-dev/pymodbus),
[paho-mqtt](https://github.com/eclipse/paho.mqtt.python),
[Flask](https://github.com/pallets/flask)

## References

- [UU P&L Company Overview](https://red.tymyrddin.dev/docs/power/territory/company)
- [ICS access and persistence play and runbooks](https://purple.tymyrddin.dev/docs/ctfs/ot-ics/access/)
- [Testing Strategy](tests/README.md)


*"The thing about electricity is, once it's out of the bottle, you can't put it back."* ~ Archchancellor Ridcully (probably)
