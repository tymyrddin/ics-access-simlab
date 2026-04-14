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

### Firewall policy

Root required. Applies `infrastructure/firewall.sh`, then verifies that allowed paths are open and everything else between zones is blocked. The `DOCKER-USER` chain is restored on exit.

```bash
sudo bash tests/smoke/test_firewall.sh
```

Skips automatically when not root.

## Dependency order

| Layer                              | Requires                        |
|------------------------------------|---------------------------------|
| `tests/unit/`                      | Python, PyYAML                  |
| `tests/integration/`               | Python, PyYAML                  |
| `tests/smoke/test_networks.sh`     | Docker, generated compose files |
| `tests/smoke/test_zones.sh`        | Docker, images built            |
| `tests/smoke/test_connectivity.sh` | Docker, images built            |
| `tests/smoke/test_firewall.sh`     | Docker, images built, root      |

To generate compose files before running smoke tests directly:

```bash
python orchestrator/generate.py
# or
./ctl generate
```

## Adding tests

The layering is intentional. A broken `generate.py` function will surface as a unit failure first, then an integration failure, then a cascade of smoke failures. Fix the layer that actually broke.