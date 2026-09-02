# Orchestrator

`generate.py` reads `ctf-config.yaml` and writes every generated file in the repo: the per-zone
docker-compose build files, the router ACL scripts, and the clab up/down helpers. The generated
files are not edited by hand. Change the config, run `./ctl generate`, and the rest follows.

```
orchestrator/
  ctf-config.yaml         single source of truth for topology and addressing
  generate.py             the generator
  firewall-rules.txt      historical iptables-policy reference (no longer consumed)
  adversary-readme.txt    the static briefing dropped on the attacker machine
```

## ctf-config.yaml

The top-level keys:

```
meta               display name, description, version
ics_process        which control-zone process to run
networks           subnet + host bridge name for each zone
enterprise_zone    hex-legacy-1, bursar-desk
operational_zone   uupl-historian, distribution-scada, uupl-eng-ws, uupl-modbus-gw
control_zone       the turbine, relays, meter, actuators, HMI, broker
dmz_zone           the Guild Quarter devices
internet_zone      wizzards-retreat (the attacker machine is its own key below)
attacker_machine   hostname, internet IP, SSH port, auth mode
```

## networks

Six host-side Linux bridges, each with a `subnet` and a `docker_name`. The `docker_name` is the
bridge on the host (`ip link show ics_internet`). The `subnet` documents the range; with the clab
fabric there is no docker IPAM, so addresses are assigned per container by the topology's `exec:`
lines.

```yaml
networks:
  internet:     { subnet: 10.10.0.0/24, docker_name: ics_internet }
  enterprise:   { subnet: 10.10.1.0/24, docker_name: ics_enterprise }
  operational:  { subnet: 10.10.2.0/24, docker_name: ics_operational }
  control:      { subnet: 10.10.3.0/24, docker_name: ics_control }
  wan:          { subnet: 10.10.4.0/24, docker_name: ics_wan }
  dmz:          { subnet: 10.10.5.0/24, docker_name: ics_dmz }
```

`infrastructure/clab-up.sh` creates the bridges and `clab-down.sh` removes them, one sudo prompt a
session. Each per-zone topology under `clab/` declares its bridges as `kind: bridge` nodes, and
topologies naming the same bridge share it. `ics_wan` is the OT/RTU placeholder: the `ops-wan-router`
boundary exists, but no field devices are deployed there yet.

## ics_process

Names the control-zone process. It is `uupl_ied`: the UU P&L Hex steam turbine with its protective
relay IEDs. The value threads through to the seed data the uupl-historian loads at startup
(`DATA_SOURCE`) and the config the engineering workstation expects (`ICS_PROCESS`), both as template
references.

## How a zone entry becomes a container

Every device entry carries an `implementation` (or `vendor`, for RTUs) that names a directory of
`COMPONENT_DIRS` in `generate.py`, which is where the Dockerfile lives. The generator turns each
entry into one compose build service on the right bridge. Attack surface is baked into the image,
not set here. A control-zone device with a sidecar looks like this:

```yaml
- name: hex-turbine-plc
  hostname: hex-turbine-plc
  ip: 10.10.3.21
  implementation: hex-turbine-plc
  env:
    ACTUATOR_FUEL_VALVE_IP: "10.10.3.51"
    MQTT_BROKER_IP: "10.10.3.60"
  sidecars:
    - name: hex-turbine-opcua
      implementation: hex-turbine-opcua
```

A sidecar with no `ip` shares its parent's network namespace; one with an `ip` gets its own address
on the control bridge. The per-zone device lists and their roles live in each zone's README, for
example [zones/control/README.md](../zones/control/README.md).

Two hosts carry a second NIC, and the generator wires both:

```yaml
enterprise_workstation:      # bursar-desk
  ip: 10.10.1.20             # enterprise
  ops_ip: 10.10.2.100        # operational
```

The dual-homing is not a security feature. It is the accumulated result of temporary access that
nobody got round to revoking.

## Templates

A value can reference another with `{{ key.path }}`:

```yaml
data_source: "{{ ics_process }}"                         # -> uupl_ied
control_network_subnet: "{{ networks.control.subnet }}"  # -> 10.10.3.0/24
```

`generate.py` loads the YAML twice: once to read the values, then again after substituting the
references. An unresolved reference raises rather than shipping literal braces into a generated file,
so a mistyped key fails the run instead of surfacing later as a broken container.

## attacker_machine

```yaml
attacker_machine:
  hostname: unseen-gate
  internet_ip: 10.10.0.5
  ssh_host_port: 2222
  auth_mode: key
```

The public entry point, single-homed on `ics_internet`, with five accounts (`ponder`, `hex`,
`ridcully`, `librarian`, `dean`). Its compose file is generated into `zones/internet/`. See the
top-level README for the two auth modes.

## Extending it

Add a component variant:

1. Drop a Dockerfile into the zone's `components/` directory.
2. Map the variant name to it in `COMPONENT_DIRS` in `generate.py`.
3. Set `implementation: <variant>` on a device in `ctf-config.yaml`.
4. Run `./ctl generate`.

Change an address: edit the `ip:` field and run `./ctl generate`. The compose files are rewritten
with the new address.

## firewall-rules.txt

Left in the tree as a record of the old policy shape. It fed `infrastructure/firewall.sh`, which hid
docker bridge gateway IPs from container scans on the previous fabric. With clab and real Linux
bridges those gateway IPs do not exist, so neither the script nor the file is consumed any more. The
live forwarding policy is the per-router `infrastructure/routers/generated/<router>-acl.sh`, still
generated here. See [clab/README.md](../clab/README.md).

## adversary-readme.txt

The briefing dropped into each adversary's home directory on the attacker machine. It is static
prose, and deliberately vague: a freshly-landed attacker is told they are on the city network and
to check `~/loot`, not handed the enterprise subnet. `generate.py` copies it to
`zones/internet/components/unseen-gate/adversary-readme.txt` (gitignored) and mounts it read-only
into the container at runtime.
