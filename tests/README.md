# Tests

Three layers. Each builds on the previous. The smoke tests do not know the unit tests exist, but they will notice if something in `generate.py` is broken.

## Unit tests

No Docker. No subprocess calls. Tests `ctf-config.yaml` schema and `generate.py` functions in isolation.

```bash
pip install -r requirements.txt
pytest tests/unit/ -v
```

Covers: required config keys, distinct subnets, template rendering, compose generation for all zones, per-router ACL script structure.

## Integration tests

No Docker. Invokes `generate.py` as a subprocess, then checks all output files exist, parse as valid YAML, and contain expected IPs. Also verifies the adversary readme has no unresolved placeholders.

```bash
pytest tests/integration/ -v
```

## Smoke tests

Require Docker and a running lab (`./ctl up`). The clab fabric brings the
whole topology up together: per-zone networks, host bridges, FRR routers,
and ACLs are all in place before any smoke test runs.

### Lab smoke tests

One smoke script per attack chain the lab supports. Each walks the chain and
asserts on visitor-realistic behaviour: passwords work, files leak via the
expected paths, modbus / IEC-104 / OPC-UA / TLS protocol probes complete,
facade shells answer `ssh user@host '<cmd>'` with the command output. They
assume `./ctl up` has already been run; each test waits for its required
services with `wait_for_port` before probing.

Three drivers aggregate the runs:

```bash
bash tests/smoke/test_phase1.sh   # IT/OT pivot chains
bash tests/smoke/test_phase2.sh   # DMZ-direct chains + neuron exfil
bash tests/smoke/test_phase3.sh   # operational/control Stage 2/3 attacks
```

Helpers live in `tests/smoke/lib.sh`; the SSH probes use paramiko inside
`attacker-machine` (no test-only software is added to lab containers), with
chained transport through wizzards-retreat for enterprise/operational
targets.

## Dependency order

| Layer                          | Requires                       |
|--------------------------------|--------------------------------|
| `tests/unit/`                  | Python, PyYAML                 |
| `tests/integration/`           | Python, PyYAML                 |
| `tests/smoke/test_*.sh`        | Full lab up via `./ctl up`     |
| `tests/smoke/test_phase*.sh`   | Full lab up via `./ctl up`     |

To generate compose files before running smoke tests directly:

```bash
python orchestrator/generate.py
# or
./ctl generate
```

## Adding tests

The layering is intentional. A broken `generate.py` function will surface as a unit failure first, then an integration failure, then a cascade of smoke failures. Fix the layer that actually broke.