# ICS access and persistence SimLab

![OT/ICS Simlab](assets/ot-ics-simlab-repo.png)

A multi-zone industrial control system for red-team practice and CTFs. It models Unseen University
Power & Light Co., Ankh-Morpork's electricity utility: infrastructure bolted together over decades,
documentation patchy, security posture emergent.

Five zones (internet, enterprise, operational, control, dmz) sit behind FRR-routed boundaries with
real iptables forwarding policy. Vulnerabilities are properties of the devices, not switches in a
config file. Nothing scripts the outcome. It follows from what a player does.

The data plane is real Linux bridges wired with explicit veth links and driven by
[containerlab](https://containerlab.dev/). One top-level YAML file picks the topology and the
component variants, and a generator turns it into the per-zone topologies and build manifests. It
all runs on a single Linux host.

## Dependencies

Linux only. Fixed-IP bridge networking needs it. Docker Desktop on macOS or Windows runs in a VM,
and the zone topology will not behave as designed there.

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

About 35 containers run at once.

| Resource | Minimum    | Recommended |
|----------|------------|-------------|
| RAM      | 4 GB       | 8 GB        |
| CPU      | 2 cores    | 4 cores     |
| Disk     | 10 GB free | 20 GB free  |

A Hetzner CX32 (4 vCPU / 8 GB) carries the full stack without complaint.

## Quickstart

```bash
./ctl up          # generate + build images + clab deploy (prompts sudo once for host bridges)
./ctl ssh         # drop into unseen-gate as ponder
./ctl verify      # audit per-node NICs, then print verification commands
./ctl down        # destroy clab labs, remove host bridges (sudo)
```

The first `./ctl up` generates an ed25519 keypair (`lab-key` / `lab-key.pub`) in the repo root and
registers it for the `ponder` account. `./ctl ssh [user]` picks that key for you, so an agent full
of other keys does not trip the login.

`lab-key` is the operator key and never goes to participants. For a cohort, `./ctl cohort-keys`
mints a separate `cohort-key` to hand out. Both keypairs are gitignored. On a shared or cloud host,
lock the repo directory down (`chmod 700 .`) so other local users cannot read them.

### All `./ctl` commands

| Command                  | What it does                                                       |
|--------------------------|--------------------------------------------------------------------|
| `./ctl up`               | Generate + build images + clab deploy + print SSH command          |
| `./ctl down`             | Destroy clab labs, remove host bridges, prune networks             |
| `./ctl ssh [user]`       | SSH into unseen-gate (default user: `ponder`)                      |
| `./ctl cohort-keys`      | Generate a participant keypair for Hetzner deployments             |
| `./ctl verify`           | Audit each node's expected in-lab NICs, then print verification commands |
| `./ctl generate`         | Regenerate the per-zone build manifests + clab helper scripts      |
| `./ctl clean`            | `down` + remove generated files                                    |
| `./ctl purge`            | `clean` + remove all images + prune build cache                    |

The config defaults to `orchestrator/ctf-config.yaml`. Point `CONFIG` at another file to run a
different one:
```bash
CONFIG=path/to/other-config.yaml ./ctl up
```

## Authentication modes

The attacker machine takes two auth modes, set by `auth_mode` in `ctf-config.yaml`.

| Mode            | Use case                                              | How it works                                                                              |
|-----------------|-------------------------------------------------------|-------------------------------------------------------------------------------------------|
| `key` (default) | Self-hosted, Hetzner, local dev                       | Pubkey auth. Keys from `adversary-keys`. `./ctl ssh` selects the right key automatically. |
| `password`      | Root-Me and platforms that publish connection strings | Password auth. Credentials set from `accounts:` in config, no key file needed.            |

Key mode is the default, for local dev and Hetzner. `./ctl up` handles the keys, as above.

```yaml
attacker_machine:
  auth_mode: key
```

Password mode is for Root-Me and platforms that publish the connection string in the room info.

```yaml
attacker_machine:
  auth_mode: password
  accounts:
    ponder: ponder
    hex: hex
    ridcully: wizzard
    librarian: books
    dean: dean
```

For example:

```
ssh ponder@ctf01.root-me.org -p 22222   (password: ponder)
ssh hex@ctf01.root-me.org    -p 22222   (password: hex)
```

## Network topology

Six host-side Linux bridges, one per Purdue layer:

| Bridge            | Subnet       | Zone                            |
|-------------------|--------------|---------------------------------|
| `ics_internet`    | 10.10.0.0/24 | Internet / city network         |
| `ics_enterprise`  | 10.10.1.0/24 | Corporate IT (Purdue L4)        |
| `ics_operational` | 10.10.2.0/24 | Site operations (Purdue L3)     |
| `ics_control`     | 10.10.3.0/24 | Area supervisory + field (L1-2) |
| `ics_dmz`         | 10.10.5.0/24 | DMZ: Guild Quarter              |
| `ics_wan`         | 10.10.4.0/24 | OT/RTU WAN (placeholder)        |

These are ordinary Linux bridges (`ip link add ... type bridge`), created and torn down by
`infrastructure/clab-up.sh` and `clab-down.sh`, one sudo prompt a session. No host IP, no docker
gateway, no NAT. Containers hang off them by the explicit veth links in the per-zone topologies
under [`clab/`](clab/).

The dual-homed hosts are where one zone bleeds into the next: `wizzards-retreat` (internet +
enterprise + operational), `bursar-desk` (enterprise + operational), `uupl-eng-ws` (operational +
control), `uupl-modbus-gw` (operational + control), `contractors-gate` (dmz + enterprise).

## Inter-zone routing

Five FRR + iptables routers hold the trust boundaries, one per boundary. Each has an interface in
two zones, runs FRR (zebra + staticd) and iptables, and answers on an SSH admin plane a visitor can
find: `admin` / `admin` drops straight into `vtysh`, and `enable` password `uupl-router` opens
configure mode. Forwarding is deny-by-default, from
`infrastructure/routers/generated/<router>-acl.sh`.

Interface IPs from `frr.conf`:

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

Once, as root on a fresh box:
```bash
bash zones/internet/components/unseen-gate/setup.sh
```
This moves the host sshd to port 2222. Reconnect there for host admin from then on.

Mint the cohort key, then set the attacker SSH port to 22 (local dev uses 2222):

```bash
./ctl cohort-keys
```

and 

```yaml
attacker_machine:
  ssh_host_port: 22
```

`cohort-key` (the private key) goes to participants via the briefing or a secure channel. Running
`./ctl cohort-keys` again rotates it cleanly between cohorts. Lock the repo directory so the key is
not world-readable (`chmod 700 /path/to/ics-access-simlab`), then deploy:

```bash
./ctl up
```
Participants connect with `ssh ponder@<hetzner-ip>`. The only sudo prompt is `./ctl up` creating
the host bridges.

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

Once the lab is up, the smoke tests exercise each attack chain end-to-end against the running stack,
one script per chain in `tests/smoke/`. Run them all:

```bash
make test-smoke
```

or run any one directly, for example:

```bash
bash tests/smoke/test_dmz_sorting_office.sh
bash tests/smoke/test_hex_legacy_facade.sh
```

Each test asserts on visitor-realistic behaviour: passwords authenticate, files leak via the
documented paths, modbus / IEC-104 / OPC-UA / TLS probes complete, facade shells return command
output. Helpers live in `tests/smoke/lib.sh`. SSH probes run inside `unseen-gate` (paramiko in its
attacker venv) and chain through `wizzards-retreat` for enterprise and operational targets, so no
test-only dependencies leak into the lab containers.

## Configuration

Edit `orchestrator/ctf-config.yaml` for topology, addressing, or component variants, then `./ctl
up`. The compose files are regenerated on every run, so editing them by hand is wasted effort.

## Contributing

Contributions welcome:

- New device types (IEDs, PMUs, RTUs, relays)
- Protocol implementations
- Additional attack scenarios and CTF configs
- Security rules and detection logic
- Hardening variants for existing components

Before adding tests, read [tests/README.md](tests/README.md) for
dependency ordering, and fix the architecture, not the test.

## Licence and usage

Licensed under the [Polyform Noncommercial Licence](LICENSE).

Fair game:

- Learning and experimentation
- Academic or independent research
- Defensive security research
- Developing and validating proof-of-concepts
- Incident response exercises
- Non-commercial red/blue team simulations

Not without a commercial licence:

- Paid workshops or training
- Consultancy or advisory services
- Internal corporate training
- Commercial product development

For a paid or commercial context, a commercial licence is required. See
[COMMERCIAL-LICENSE.md](COMMERCIAL-LICENSE.md). If the use case is a grey area,
[ambiguity is solvable](https://tymyrddin.dev/contact/); silence is not.

---

*"The thing about electricity is, once it's out of the bottle, you can't put it back."* ~ Archchancellor Ridcully (probably)
