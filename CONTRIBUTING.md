# Contributing

*"The thing about keeping a city's lights on is that you can't simply wave your hands and hope for the best. There are rules, testing procedures, and an understanding that if something breaks, someone will notice. Immediately."*

Thank you for your interest in contributing. This project simulates critical infrastructure: the sort that, if it fails in reality, leaves people quite literally in the dark. The irony of deliberately building it to be exploitable is not lost on anyone involved.

## Contribution philosophy

This platform exists to improve security. Contributions serve that purpose whether you are adding new attack surfaces, defensive capabilities, protocol implementations, or documentation that helps others understand industrial control systems.

Contributions are welcome from:
- Security researchers exploring ICS/SCADA vulnerabilities
- Industrial control professionals sharing domain knowledge
- CTF designers building training scenarios
- Anyone who believes critical infrastructure security matters

The standard: rigour, testing, and an understanding that a poorly-wired container in a security research platform can mislead the people it is trying to teach.

## Before contributing

### Understand the licence

This project uses the Polyform Noncommercial Licence 1.0.0, with a security research exception.

What this means for contributors:
- The project remains under the copyright of Ty Myrddin (© 2026)
- Contributions are licenced under the same terms
- By submitting code, you grant the project maintainers perpetual rights to use your contribution under both noncommercial and commercial licences
- You retain copyright of your work, but acknowledge the dual-licensing model
- If you are uncomfortable with this, discuss it before contributing

The security research exception means your work can be used for legitimate research, vulnerability analysis, and defensive security (even if that involves attack tooling). See [SECURITY-RESEARCH-EXCEPTION.md](SECURITY-RESEARCH-EXCEPTION.md).

Organisations using this for paid services need a commercial licence. Contributions may be used in that context. If this concerns you, [ask first](https://tymyrddin.dev/contact/).

## Code standards

### Architecture

The platform generates all Docker Compose stacks from a single source of truth: `orchestrator/ctf-config.yaml`. Contributions that bypass this (hand-editing compose files, hardcoding values outside the config) will be rejected.

Follow these conventions:
- New devices and zones are added via `ctf-config.yaml` and the corresponding generator logic in `generate.py`
- Network attachments, IPs, and port mappings come from config, not hardcoded values
- Vulnerabilities are properties of device containers, not toggleable config flags
- Zone boundaries are enforced by the generated firewall rules

If `./ctl generate` produces valid compose files and `./ctl up` brings them up cleanly, you are on the right track.

### Testing

The project has three test layers. Run them before submitting.

```bash
# Unit tests (no Docker needed)
pytest tests/unit/ -v

# Integration tests (no Docker needed)
pytest tests/integration/ -v

# Smoke tests (Docker needed, images needed)
bash tests/smoke/test_zones.sh
bash tests/smoke/test_connectivity.sh
```

See [tests/README.md](tests/README.md) for full details and dependency ordering.

New devices and zones need at minimum:
- A unit test in `tests/unit/test_generate.py` verifying their compose output
- A spot-check in `tests/integration/test_artifacts.py` for expected IPs

## What to contribute

New device or container:
- Lives under `zones/<zone>/components/<name>/`
- Has its own Dockerfile and necessary config files
- Is wired into `ctf-config.yaml` with a stable IP in the correct zone range
- Appears in the relevant zone generator function in `generate.py`
- Has a README documenting its role, services, and any deliberate vulnerabilities

New zone or CTF scenario:
- Adds a zone block to `ctf-config.yaml`
- Has a corresponding generator function in `generate.py`
- Has network and firewall entries
- Is described in `docs/PLAN.md`

## What not to contribute

- Malware or destructive payloads intended for production systems (this is a simulator)
- Exploits for active 0-days without coordinated responsible disclosure
- Compose files hand-edited around the generator
- Features that look impressive but serve no training or research purpose

If you are uncertain whether your idea fits, [ask first](https://tymyrddin.dev/contact/).

## Contribution process

### Check for existing work

- Search [issues](https://github.com/ninabarzh/ics-access-simlab/issues) to avoid duplication
- Large features benefit from an issue discussing approach before implementation
- If fixing a bug, create an issue first describing the problem

### Fork and branch

```bash
git clone https://github.com/ninabarzh/ics-access-simlab.git
cd ics-access-simlab
git checkout -b feature/your-feature-name
```

### Develop and test

```bash
# Requirements for running generate.py and tests
pip install pyyaml pytest

# Regenerate compose files after config changes
python orchestrator/generate.py
# or
./ctl generate

# Run tests
pytest tests/unit/ -v
pytest tests/integration/ -v

# Start the stack
./ctl up
./ctl verify
```

### Submit a pull request

Before submitting:
- [ ] All existing tests pass locally
- [ ] New functionality has tests
- [ ] `./ctl up` completes without errors (for topology changes)
- [ ] Documentation updated where relevant
- [ ] Commit messages reference related issues

PR descriptions include: what the change does, how to test it, any breaking changes, and related issue numbers.

### Code review

Expect feedback. Changes may be requested for architectural compliance, test coverage, or documentation clarity. This is not personal: the platform is used to train people who then go near real infrastructure.

If you do not hear back within a week, a polite ping on the PR is appropriate.

## Security research ethics

This platform exists to improve security, not to cause harm.

Operate within environments you own or have permission to test. If you discover a vulnerability pattern applicable to real systems, follow coordinated responsible disclosure. Do not use techniques developed here against systems without authorisation.

If you discover a security issue in the platform itself (an unintended attack surface, as opposed to one of the many deliberate ones), report it privately first. Use GitHub's [private security advisory feature](https://github.com/ninabarzh/ics-access-simlab/security/advisories) or [contact directly](https://tymyrddin.dev/contact/).

## Development environment

Linux only. Docker's fixed-IP bridge networking requires it. Docker Desktop on macOS or Windows uses a VM and the zone topology will not behave as intended.

Requirements:
- Docker Engine 24+
- Docker Compose v2.20+ (plugin, not standalone `docker-compose`)
- Python 3.10+ and PyYAML (for the orchestrator and tests)

Setup:

```bash
git clone https://github.com/ninabarzh/ics-access-simlab.git
cd ics-access-simlab

# Start the full stack
./ctl up

# Check zone connectivity
./ctl verify

# Run the test suite (no Docker needed for unit and integration)
pip install pyyaml pytest
pytest tests/unit/ tests/integration/ -v
```

### Project structure

```
orchestrator/
├── ctf-config.yaml      # source of truth for topology
├── generate.py          # generates all compose files from config
└── templates/           # compose and script templates

zones/
├── internet/            # unseen-gate (attacker), wizzards-retreat (admin@home)
├── enterprise/          # legacy workstations, enterprise hosts
├── operational/         # historian, SCADA, engineering workstation
├── control/             # PLCs, relays, HMI, actuators, MQTT broker
├── dmz/                 # 10 DMZ devices (Neuron, umati, syslog, etc.)
└── field-devices/       # WAN-side RTUs

infrastructure/
├── networks/            # Docker Compose for shared bridge networks
└── firewall.sh          # generated iptables rules for DOCKER-USER chain

tests/
├── unit/                # config schema and generator function tests
├── integration/         # end-to-end generate.py output checks
└── smoke/               # Docker-based network and connectivity tests

books/                   # CTF walkthrough and attack path guides
docs/                    # Architecture, plan, requirements, resources
```

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before modifying the topology or generator.

## Documentation

When adding features, update the relevant documentation:
- `README.md` for high-level changes (new scenarios, major topology changes)
- `docs/PLAN.md` for step status and pending decisions
- Zone READMEs for new devices (role, services, deliberate vulnerabilities)
- `books/` for new attack paths

Good documentation means Ponder does not have to explain the same topology choice in every PR review.

## Getting help

- Issues: [GitHub issues](https://github.com/ninabarzh/ics-access-simlab/issues) for bugs and feature requests
- Contact: for licensing, commercial use, or sensitive security topics: https://tymyrddin.dev/contact/

## Acknowledgements

By contributing, you help improve the security of critical infrastructure, even if only by building a better training ground for those learning to defend it. That matters.

The Patrician appreciates competence. Ponder appreciates code that does not break at 3 in the morning. Both appreciate contributors who understand that infrastructure security is not a game, but apparently, a very elaborate roleplay.

Thank you for your contribution.

Licence: by submitting a contribution, you agree to licence your work under the project's Polyform Noncommercial Licence, and grant the maintainers rights to use it under both noncommercial and commercial licences.

Code of conduct: professional, respectful, focused on the work. See [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).

Last Updated: April 2026