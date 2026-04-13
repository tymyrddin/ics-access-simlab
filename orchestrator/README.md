# Orchestrator

`generate.py` reads `ctf-config.yaml` and produces every generated file in the
repository. Nothing outside this directory should be edited directly: change
the config, run `make generate`, and the rest follows.

```
orchestrator/
  ctf-config.yaml         single source of truth for topology and addressing
  generate.py             code generator
  firewall-rules.txt      iptables policy template (placeholders resolved by generate.py)
  adversary-readme.txt    jump host README template (placeholders resolved by generate.py)
```

---

## ctf-config.yaml structure

```
meta                      display name, description, version
ics_process               which ICS physical process to run in the control zone
networks                  subnet + docker network name for each of the five zones
enterprise_zone           legacy-workstation, enterprise-workstation
operational_zone          historian, scada-server, engineering-workstation
control_zone              device list for the IED network (patched into configuration.json)
field_devices_zone        city RTUs on ics_wan (the OT/RTU network)
jump_host                 hostname, internet IP, and enterprise IP for the jump host
```

---

## networks

Five Docker bridge networks. Each has a `subnet` and a `docker_name`.
The `docker_name` is what Docker actually creates; `subnet` is the IPAM range.

```yaml
networks:
  internet:     subnet: 10.10.0.0/24   docker_name: ics_internet
  enterprise:   subnet: 10.10.1.0/24   docker_name: ics_enterprise
  operational:  subnet: 10.10.2.0/24   docker_name: ics_operational
  control:      subnet: 10.10.3.0/24   docker_name: ics_control
  wan:          subnet: 10.10.4.0/24   docker_name: ics_wan
```

All five are created by the shared `infrastructure/networks/docker-compose.yml`
stack and declared `external` in every zone compose file. Zone stacks attach
to them, never recreate them.

`ics_internet` is the public network / internet. The jump host is always
dual-homed here (`internet_ip`) and on enterprise (`ip`). Future adversary-side
endpoints live here. If a specific RTU appears here too, that is an RTU-level
misconfiguration: not a flag.

`ics_wan` is the OT/RTU network. RTUs are on it because they use public
cellular IPs with no private APN and no VPN. SCADA polls them outbound from
`ics_operational` into `ics_wan`. Enterprise cannot reach it directly.

---

## ics_process

Selects the physical process that runs in the control zone:

| Value | Description |
|---|---|
| `uupl_ied` | **Default.** UU P&L Hex Steam Turbine + protective relay IEDs |
| `intelligent_electronic_device` | Curtin ICS-SimLab built-in generic IED demo |
| `water_bottle_factory` | Curtin ICS-SimLab built-in |
| `smart_grid` | Curtin ICS-SimLab built-in |

Changing `ics_process` affects three things:
- Which `configuration.json` is patched and passed to ICS-SimLab
- Which seed data the historian loads at startup (`DATA_SOURCE` env var)
- What device names and logic the engineering workstation expects

The config dir for each process is resolved in `generate.py:ICS_PROCESS_CONFIGS`.
The `uupl_ied` config lives in `zones/control/config/uupl_ied/`.
The Curtin built-ins live in `curtin-ics-simlab/config/`.

---

## enterprise_zone

Two machines. Adversaries reach this zone first from the jump host.

### legacy_workstation

```yaml
legacy_workstation:
  hostname: hex-legacy-1
  ip: 10.10.1.10
  implementation: win95-era
```

Single-homed on `ics_enterprise`. The `implementation` key selects the
Dockerfile from `zones/enterprise/components/`. The `win95-era` implementation
is a Samba null-session / FTP anon / Telnet era machine: attack surface is
baked into the image, not configured here.

### enterprise_workstation

```yaml
enterprise_workstation:
  hostname: bursar-desk
  ip: 10.10.1.20
  ops_ip: 10.10.2.100
  implementation: enterprise-generic
```

Dual-homed: `ip` on `ics_enterprise`, `ops_ip` on `ics_operational`. This is
the IT/OT boundary pivot. The dual-homing is not a security feature, it is
the accumulated result of "temporary" network access never revoked.

---

## operational_zone

Three machines. Not directly reachable from the enterprise zone (firewall),
but reachable via the enterprise_workstation's `ops_ip`.

### historian

```yaml
historian:
  hostname: uupl-historian
  ip: 10.10.2.10
  implementation: historian-v1
  data_source: "{{ ics_process }}"
```

Single-homed on `ics_operational`. Runs a Flask + SQLite service. The
`data_source` template resolves to the `ics_process` value, telling the
historian which time-series seed data to load at startup.
`{{ ics_process }}` is a template reference: `generate.py` resolves
`{{ key.path }}` patterns from the config before writing compose files.

### scada_server

```yaml
scada_server:
  hostname: distribution-scada
  ip: 10.10.2.20
  implementation: scada-generic
  historian_ip: 10.10.2.10
```

Single-homed on `ics_operational`. `historian_ip` is passed as an environment
variable so the SCADA server knows where to pull aggregated data from. If you
change the historian's IP, update `historian_ip` here too.

### engineering_workstation

```yaml
engineering_workstation:
  hostname: uupl-eng-ws
  ip: 10.10.2.30
  ctrl_ip: 10.10.3.100
  implementation: engineering-workstation-generic
  ics_process: "{{ ics_process }}"
  control_network_subnet: "{{ networks.control.subnet }}"
```

Dual-homed: `ip` on `ics_operational`, `ctrl_ip` on `ics_control`. The pivot
into the control zone. `ics_process` and `control_network_subnet` are passed as
environment variables so the workstation's config files reference the correct
device IPs and process type. Both use template references that resolve
automatically.

---

## control_zone

```yaml
control_zone:
  devices:
    - { name: hmi_main,               ip: 10.10.3.10 }
    - { name: hex_turbine_controller,  ip: 10.10.3.21 }
    ...
```

This list is the authoritative IP assignment for every device in the IED
network. `generate.py:generate_control_config()` reads this list, compares it
to the current IPs in `configuration.json`, builds an `old_ip → new_ip` map,
and rewrites the JSON, patching device `network.ip` fields, all
`outbound_connections` and `inbound_connections` IPs, and the `ip_networks`
subnet entry. This runs before ICS-SimLab is invoked so the simulation always
starts with the addresses from the config.

**What the devices are:**

| Name | Type | IP | Role |
|---|---|---|---|
| `hmi_main` | HMI | 10.10.3.10 | Operator display. Polls PLC and IEDs. Accepts governor setpoint and emergency stop commands. |
| `hex_turbine_controller` | PLC | 10.10.3.21 | Runs `turbine_plc.py`. Reads RPM/temp/pressure from sensors, commands throttle valve and governor. Raises overspeed/overtemp/overpressure alarms. |
| `ied_relay_a` | IED | 10.10.3.31 | Protective relay, Dolly Sisters feeder. Monitors line A voltage and current. Trips `breaker_a` on overcurrent. |
| `ied_relay_b` | IED | 10.10.3.32 | Protective relay, Nap Hill feeder. Same logic as relay_a on line B. |
| `ied_meter_main` | IED | 10.10.3.33 | Revenue meter. Reads voltage and current from line A sensors, computes kW. No actuation. |
| `turbine_rpm_sensor` | Sensor | 10.10.3.41 | Modbus TCP endpoint. Publishes `turbine_rpm` from the HIL. |
| `turbine_temp_sensor` | Sensor | 10.10.3.42 | Publishes `turbine_temperature`. |
| `turbine_pressure_sensor` | Sensor | 10.10.3.43 | Publishes `turbine_pressure`. |
| `line_voltage_sensor_a` | Sensor | 10.10.3.44 | Publishes `line_voltage_a`. Used by both `ied_relay_a` and `ied_meter_main`. |
| `line_current_sensor_a` | Sensor | 10.10.3.45 | Publishes `line_current_a`. Used by both `ied_relay_a` and `ied_meter_main`. |
| `line_voltage_sensor_b` | Sensor | 10.10.3.46 | Publishes `line_voltage_b`. Used by `ied_relay_b`. |
| `line_current_sensor_b` | Sensor | 10.10.3.47 | Publishes `line_current_b`. Used by `ied_relay_b`. |
| `throttle_valve` | Actuator | 10.10.3.51 | Accepts `throttle_position` from the PLC. Feeds the HIL. |
| `governor_actuator` | Actuator | 10.10.3.52 | Accepts `governor_setpoint`. Feeds the HIL. |
| `breaker_a` | Actuator | 10.10.3.53 | Accepts `breaker_a_state` (open/closed) from `ied_relay_a`. |
| `breaker_b` | Actuator | 10.10.3.54 | Accepts `breaker_b_state` from `ied_relay_b`. |

**What does NOT go here:** `engineering-workstation` (`ctrl_ip: 10.10.3.100`) is on the
control network but is managed by `operational_zone`. It is not an ICS field
device and does not get a `configuration.json` entry.

**What does NOT change when you edit this list:** register maps, logic files
(`turbine_plc.py`, `relay_logic.py`, `meter_logic.py`), and the physics
simulation (`turbine_hil.py`) all live in `zones/control/config/uupl_ied/` and
are not generated. Only the IP addresses in `configuration.json` are patched.

---

## field_devices_zone

```yaml
field_devices_zone:
  city_rtus:
    - name: dolly-sisters-substation
      hostname: rtu-dolly-1
      ip: 10.10.4.10
      vendor: generic-rtu-v1
      location: "Dolly Sisters Substation, Ankh-Morpork"
    ...
```

City RTUs live on `ics_wan` (10.10.4.0/24), the WAN / city network, separate from
the control zone. They get their own compose file: `zones/field-devices/docker-compose.yml`.
Each RTU has a WAN-facing IP: this is the exposure. SCADA's outbound Modbus poll
crosses from `ics_operational` to `ics_wan` via cross-network Docker routing, correctly
modelling a SCADA head-end polling internet-routable RTU addresses.

Each entry has:

| Field | Purpose |
|---|---|
| `name` | Logical identifier used in RTU environment (`RTU_NAME`) |
| `hostname` | Docker container hostname and service name in the compose file |
| `ip` | Static IP on `ics_wan` |
| `vendor` | Selects the Dockerfile from `COMPONENT_DIRS` in `generate.py` |
| `location` | Passed as `RTU_LOCATION` env var (appears in SNMP sysDescr, banners) |

`downstream_devices` per RTU (reclosers, smart meters, per-substation inner networks)
is reserved for future expansion.

The `generic-rtu-v1` vendor implementation runs Modbus TCP (port 502) and SNMP
(port 161, community `public`). Attack surface is baked into the image.
Add entries to expand the distribution network; each gets its own container.

---

## jump_host

```yaml
jump_host:
  hostname: unseen-gate
  internet_ip: 10.10.0.5
  ip: 10.10.1.5
```

The sole public entry point. A container dual-homed on `ics_internet` (`internet_ip`)
and `ics_enterprise` (`ip`). The `ics_internet` interface is where external SSH
connections arrive; `ics_enterprise` is the pivot point into the enterprise zone.
Five
adversary accounts (`moist`, `teatime`, `carrot`, `angua`, `vimes`). Key-only
SSH. Compose file and adversary README are generated into
`infrastructure/jump-host/`.

---

## Templates

Values in `ctf-config.yaml` can reference other values using `{{ key.path }}`
syntax:

```yaml
data_source: "{{ ics_process }}"           # resolves to "uupl_ied"
ics_process: "{{ ics_process }}"           # same
control_network_subnet: "{{ networks.control.subnet }}"  # resolves to "10.10.3.0/24"
```

`generate.py:_render_templates()` does a two-pass YAML load: parse first to
get values, then substitute `{{ }}` references, then parse again. Unresolved
references are left intact rather than raising an error.

---

## firewall-rules.txt

The inter-zone iptables policy. `generate.py:generate_firewall_sh()` strips
comment lines, substitutes `{placeholder}` addresses from the config, and
wraps the result in a root-check + bash header, writing
`infrastructure/firewall.sh`.

**Placeholders and what they resolve to:**

| Placeholder | Source in ctf-config.yaml |
|---|---|
| `{internet}` | `networks.internet.subnet` |
| `{enterprise}` | `networks.enterprise.subnet` |
| `{operational}` | `networks.operational.subnet` |
| `{control}` | `networks.control.subnet` |
| `{wan}` | `networks.wan.subnet` |
| `{historian}` | `operational_zone.historian.ip` |
| `{scada}` | `operational_zone.scada_server.ip` |
| `{eng_ws}` | `operational_zone.engineering_workstation.ip` |

Note the difference: zone-wide rules use subnet placeholders; host-specific
rules use individual IP placeholders. This means you can allow historian:8080
without opening the whole operational subnet.

**The policy:**

```
RELATED,ESTABLISHED → ACCEPT           (stateful: return traffic is always allowed)

internet → enterprise                  DROP     (jump host bridges via dual-homing, not routing)
internet → operational                 DROP
internet → control                     DROP
internet → wan                         DROP

enterprise → historian:8080            ACCEPT
enterprise → scada:8080                ACCEPT
enterprise → eng_ws:22                 ACCEPT
enterprise → operational (rest)        DROP

enterprise → control                   DROP
enterprise → wan                       DROP

eng_ws → control:502                   ACCEPT   (Modbus maintenance from eng workstation)
operational → control (rest)           DROP

scada → wan:502                        ACCEPT   (Modbus poll — crosses ics_operational → ics_wan)
eng_ws → wan:502                       ACCEPT
scada → wan:161/udp                    ACCEPT   (SNMP)
eng_ws → wan:161/udp                   ACCEPT
operational → wan (rest)               DROP

control → enterprise                   DROP     (control zone does not initiate)
control → operational                  DROP

wan → internet                         DROP     (RTUs do not initiate)
wan → enterprise                       DROP
wan → operational                      DROP
wan → control                          DROP

(final rule)                           RETURN   (Docker handles everything else)
```

The final `RETURN` hands unmatched traffic back to Docker's default chain,
which allows intra-zone traffic (same bridge) and drops cross-zone traffic not
explicitly permitted above.

Rules are evaluated top to bottom. The `RELATED,ESTABLISHED` rule at the top
means that once a connection is established through an ACCEPT rule, return
packets are not re-evaluated against the DROP rules -> so the policy is
stateful in the expected direction.

**To change the policy:** edit `firewall-rules.txt`, run `make generate`.
The `.txt` file is committed; `infrastructure/firewall.sh` is generated and
gitignored.

---

## adversary-readme.txt

Template for the file placed in each adversary's home directory on the jump
host. Resolved by `generate.py:generate_adversary_readme()` using the same
`{placeholder}` substitution as the firewall rules.

| Placeholder | Resolves to |
|---|---|
| `{enterprise_subnet}` | `networks.enterprise.subnet` |
| `{legacy_ws_ip}` | `enterprise_zone.legacy_workstation.ip` |
| `{ent_ws_ip}` | `enterprise_zone.enterprise_workstation.ip` |

The resolved file is written to `infrastructure/jump-host/adversary-readme.txt`
(gitignored) and mounted read-only into the jump host container at runtime.

---

## Adding a new component variant

1. Create a Dockerfile in the appropriate zone's `components/` directory.
2. Add an entry to `COMPONENT_DIRS` in `generate.py` mapping the variant name to that directory.
3. Set `implementation: <your-variant>` (or `vendor: <your-variant>` for RTUs) in `ctf-config.yaml`.
4. Run `make generate`.

## Adding a city RTU

Add an entry under `field_devices_zone.city_rtus` in `ctf-config.yaml`.
Pick an unused IP on `10.10.4.0/24`. Run `make generate`. The new container
appears in `zones/field-devices/docker-compose.yml` automatically.

## Changing an IP address

Edit the relevant `ip:` field in `ctf-config.yaml`. Run `make generate`.
For control zone devices, `generate.py` patches `configuration.json` and
rewrites all connection references that pointed to the old IP. For all zones,
the compose files are regenerated with the new address.
