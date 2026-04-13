# Shared zone networks

The `docker-compose.yml` in this directory is *generated* by the orchestrator.
It must exist before any zone stack can start, because all zone stacks declare
their networks as `external`.

## Generate it

```bash
python orchestrator/generate.py [orchestrator/ctf-config.yaml]
```

This reads the `networks:` block from `ctf-config.yaml` and writes
`infrastructure/networks/docker-compose.yml` defining the four zone networks:

| Network           | Subnet       | Purpose                                          |
|-------------------|--------------|--------------------------------------------------|
| `ics_internet`    | 10.10.0.0/24 | Internet / public network (attacker machine lives here) |
| `ics_enterprise`  | 10.10.1.0/24 | Enterprise zone internal                         |
| `ics_operational` | 10.10.2.0/24 | Operational zone internal                        |
| `ics_control`     | 10.10.3.0/24 | Control zone (ICS-SimLab)                        |
| `ics_wan`         | 10.10.4.0/24 | OT/RTU network (cellular, no private APN)        |

## Startup order

Networks must be created before zone stacks start.
`start.sh` (also generated) handles this in the correct order:

```
infrastructure/networks/docker-compose.yml   up -d   ← first
zones/enterprise/docker-compose.yml          up -d
zones/operational/docker-compose.yml         up -d
zones/control/docker-compose.yml             up -d   ← last
```

## Subnets

To change subnets (e.g. to avoid conflicts with the host network),
edit `orchestrator/ctf-config.yaml` under the `networks:` block,
then re-run `generate.py`.
