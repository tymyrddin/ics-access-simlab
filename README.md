# ICS access and persistence SimLab

A multi-zone Industrial Control System simulation built for realistic red team exercises and CTF scenarios. The
environment models the operational infrastructure of Unseen University Power & Light Co., Ankh-Morpork's primary
utility provider with an infrastructure assembled over decades, documentation patchy, cybersecurity posture: emergent.

Five network zones (internet, enterprise, operational, control, dmz) are separated by FRR-routed boundaries with
real iptables forwarding policy. Vulnerabilities are properties of the simulated systems, not configuration
options. Consequences emerge from what players actually do.

The data plane runs on real Linux bridges with explicit veth links, orchestrated by
[containerlab](https://containerlab.dev/). A top-level YAML config selects the topology and component variants;
a code generator produces the per-zone topology files and the container-build manifests from this config. The
environment runs on a single Linux host.

## Dependencies

Linux only. Docker's fixed-IP bridge networking requires Linux. Docker Desktop on macOS/Windows uses a VM and
the zone topology will not behave as designed.

| Dependency     | Version     | Notes                                                                |
|----------------|-------------|----------------------------------------------------------------------|
| Linux          | kernel 5.x+ | Ubuntu 22.04 / Debian 12 tested                                      |
| Docker Engine  | 24+         | Not Docker Desktop                                                   |
| Docker Compose | v2.20+      | Plugin (`docker compose`), used to build the application images      |
| containerlab   | 0.50+       | `bash -c "$(curl -sL https://get.containerlab.dev)"` ; needs sudo    |
| sudo           | any         | clab needs CAP_NET_ADMIN to create/destroy host bridges (one prompt) |
| Python         | 3.10+       | For the orchestrator                                                 |
| PyYAML         | any recent  | `pip install pyyaml` or `apt install python3-yaml`                   |

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
./ctl up          # generate + build images + clab deploy (prompts sudo once for host bridges)
./ctl ssh         # drop into unseen-gate as ponder
./ctl verify      # print Step 2 verification commands
./ctl down        # destroy clab labs, remove host bridges (sudo)
```

On first `./ctl up`, a dedicated ed25519 keypair (`lab-key` / `lab-key.pub`) is generated in the repo root and
registered for user `ponder`. Use `./ctl ssh [user]` to connect: it selects the lab key automatically, so
participants with many keys in their SSH agent won't hit authentication failures.

`lab-key` is the operator key, never distributed to participants. For Hetzner deployments, run
`./ctl cohort-keys` to generate a separate participant keypair and distribute `cohort-key` to the cohort.

Both keypairs are gitignored. On a shared or cloud host, restrict repo directory permissions so other local
users cannot read them (`chmod 700 .` or equivalent).

### All `./ctl` commands

| Command                  | What it does                                                       |
|--------------------------|--------------------------------------------------------------------|
| `./ctl up`               | Generate + build images + clab deploy + print SSH command          |
| `./ctl down`             | Destroy clab labs, remove host bridges, prune networks             |
| `./ctl ssh [user]`       | SSH into unseen-gate (default user: `ponder`)                      |
| `./ctl cohort-keys`      | Generate a participant keypair for Hetzner deployments             |
| `./ctl verify`           | Print verification commands for the current scenario               |
| `./ctl generate`         | Regenerate the per-zone build manifests + clab helper scripts      |
| `./ctl clean`            | `down` + remove generated files                                    |
| `./ctl purge`            | `clean` + remove all images + prune build cache                    |

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

Six host-side Linux bridges, each mapped to a Purdue model layer:

| Bridge           | Subnet         | Zone                            |
|------------------|----------------|---------------------------------|
| `ics_internet`   | 10.10.0.0/24   | Internet / city network         |
| `ics_enterprise` | 10.10.1.0/24   | Corporate IT (Purdue L4)        |
| `ics_operational`| 10.10.2.0/24   | Site operations (Purdue L3)     |
| `ics_control`    | 10.10.3.0/24   | Area supervisory + field (L1-2) |
| `ics_dmz`        | 10.10.5.0/24   | DMZ: Guild Quarter              |
| `ics_wan`        | 10.10.4.0/24   | OT/RTU WAN (placeholder)        |

The bridges are real Linux bridges (`ip link add ... type bridge`), created and destroyed by
`infrastructure/clab-up.sh` / `clab-down.sh` (one sudo prompt per session). They have no host-side IPs,
no docker-managed gateway, no NAT rule. Containers attach to them via explicit veth links declared in
the per-zone clab topologies under [`clab/`](clab/).

Key dual-homed hosts: `wizzards-retreat` (internet + enterprise + operational), `bursar-desk`
(enterprise + operational), `uupl-eng-ws` (operational + control),
`uupl-modbus-gw` (operational + control), `contractors-gate` (dmz + enterprise).

## Inter-zone routing

Zone isolation is enforced by five FRR + iptables router containers, one per trust boundary. Each
router has two zone interfaces, runs FRR (zebra + staticd) for routing and iptables for forwarding
policy, and exposes a visitor-discoverable SSH admin plane (`admin` / `admin` lands directly in
`vtysh`; `enable` password `uupl-router` opens configure mode). The forwarding ACL still comes from
`infrastructure/routers/generated/<router>-acl.sh`, deny-by-default.

The five gateways (interface IPs from `frr.conf`):

| Router         | A side                       | B side                          |
|----------------|------------------------------|---------------------------------|
| inet-dmz-fw    | `10.10.5.200` (dmz)          | `10.10.0.200` (internet)        |
| dmz-ent-fw     | `10.10.5.201` (dmz)          | `10.10.1.201` (enterprise)      |
| ent-ops-fw     | `10.10.1.202` (enterprise)   | `10.10.2.202` (operational)     |
| ops-ctrl-fw    | `10.10.3.203` (control)      | `10.10.2.203` (operational)     |
| ops-wan-router | `10.10.2.204` (operational)  | `10.10.4.204` (wan)             |

See [clab/README.md](clab/README.md) for the topology shape, the FRR router image, and known
limitations (notably the upstream Scada-LTS schema migration bug).

## Hetzner deployment

One-time host setup (run once as root on a fresh instance):
```bash
bash zones/internet/components/unseen-gate/setup.sh
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
```

(`./ctl up` itself prompts for sudo once when it creates the host Linux bridges via
`infrastructure/clab-up.sh`; no separate firewall step.)

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

### Lab smoke tests

Once the lab is up (`./ctl up`), the smoke tests verify each attack chain
end-to-end against the running stack. Three drivers cover the 13 chains:

```bash
bash tests/smoke/test_phase1.sh   # IT/OT pivot chains
bash tests/smoke/test_phase2.sh   # DMZ-direct + neuron covert exfil
bash tests/smoke/test_phase3.sh   # inner-zone Stage 2/3 attacks
bash tests/smoke/test_phase4.sh   # L2/L3 fabric (FRR admin plane, etc.)
bash tests/smoke/test_phase5.sh   # persistence (keys, cron, scheduled tasks)
```

Each test asserts on visitor-realistic behaviour: passwords authenticate,
files leak via the documented paths, modbus / IEC-104 / OPC-UA / TLS probes
complete, facade shells return command output. Helpers live in
`tests/smoke/lib.sh`; SSH probes run paramiko inside `unseen-gate` and
chain through wizzards-retreat for enterprise / operational targets, so no
test-only dependencies are added to lab containers.

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

*"The thing about electricity is, once it's out of the bottle, you can't put it back."* ~ Archchancellor Ridcully (probably)
