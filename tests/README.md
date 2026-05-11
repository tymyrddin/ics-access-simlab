# Tests

Three layers. Each builds on the previous. The smoke tests do not know the unit tests exist, but they will notice if something in `generate.py` is broken.

## Unit tests

No Docker. No subprocess calls. Tests `ctf-config.yaml` schema and `generate.py` functions in isolation.

```bash
pip install -r requirements.txt
pytest tests/unit/ -v
```

Covers: required config keys, distinct subnets, template rendering, compose generation for all zones, firewall script structure.

## Integration tests

No Docker. Invokes `generate.py` as a subprocess, then checks all output files exist, parse as valid YAML, and contain expected IPs. Also verifies the adversary readme has no unresolved placeholders.

```bash
pytest tests/integration/ -v
```

## Smoke tests

Require Docker. Each script starts what it needs and tears down on exit.

### Networks

No images needed. Starts the networks stack and checks all zone networks exist with correct names and subnets.

```bash
bash tests/smoke/test_networks.sh
```

### Zone containers

Images needed. Starts enterprise and operational zones, checks containers are running, IPs are correct, and dual-homed containers have a foot in both expected networks.

```bash
bash tests/smoke/test_zones.sh
```

### Inter-zone connectivity

Images needed. Starts all zones without firewall rules applied. Verifies intra-zone reachability and that dual-homed containers respond on both their network interfaces.

Cross-zone routing at Layer 3 through a dual-homed container is intentionally not tested here. The realistic attack path is to SSH in and connect from there.

```bash
bash tests/smoke/test_connectivity.sh
```

### Firewall policy (legacy)

`tests/smoke/test_firewall.sh` exists from the docker-bridge fabric era when
`infrastructure/firewall.sh` was applied on the host. The clab fabric moves
forwarding policy into the FRR + iptables router containers, where the
runbook smoke tests already exercise it implicitly (e.g. cross-zone paths
blocked vs. allowed). The legacy script may now skip or fail; the
runbook-phase suites are the active acceptance tests.

### Runbook smoke tests

One smoke script per runbook in `books/`. Each walks the runbook stages and
asserts on visitor-realistic behaviour: passwords work, files leak via the
expected paths, modbus / IEC-104 / OPC-UA / TLS protocol probes complete,
facade shells answer `ssh user@host '<cmd>'` with the command output. They
assume `./ctl up` has already been run; each test waits for its required
services with `wait_for_port` before probing.

Three drivers aggregate the runs:

```bash
bash tests/smoke/test_runbooks_phase1.sh   # IT/OT pivot chains
bash tests/smoke/test_runbooks_phase2.sh   # DMZ-direct chains + neuron exfil
bash tests/smoke/test_runbooks_phase3.sh   # operational/control Stage 2/3 attacks
```

Cumulative: 13 runbooks, 109 assertions. Helpers live in
`tests/smoke/lib.sh`; the SSH probes use paramiko inside `attacker-machine`
(no test-only software is added to lab containers), with chained transport
through wizzards-retreat for enterprise/operational targets.

## Dependency order

| Layer                              | Requires                        |
|------------------------------------|---------------------------------|
| `tests/unit/`                      | Python, PyYAML                  |
| `tests/integration/`               | Python, PyYAML                  |
| `tests/smoke/test_networks.sh`     | Docker, generated compose files |
| `tests/smoke/test_zones.sh`        | Docker, images built            |
| `tests/smoke/test_connectivity.sh` | Docker, images built            |
| `tests/smoke/test_firewall.sh`     | Legacy (docker-bridge fabric), no longer maintained |
| `tests/smoke/test_runbooks_phase*.sh` | Full lab up via `./ctl up`    |

To generate compose files before running smoke tests directly:

```bash
python orchestrator/generate.py
# or
./ctl generate
```

## Adding tests

The layering is intentional. A broken `generate.py` function will surface as a unit failure first, then an integration failure, then a cascade of smoke failures. Fix the layer that actually broke.