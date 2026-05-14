#!/usr/bin/env python3
"""
ICS-Access-SimLab, Orchestrator

Reads ctf-config.yaml and generates the per-zone artefacts the clab fabric
consumes:

  zones/enterprise/docker-compose.yml          application image builds
  zones/operational/docker-compose.yml         application image builds
  zones/control/docker-compose.yml             application image builds (turbine PLC,
                                               HMI, IEDs, actuators)
  zones/dmz/docker-compose.yml                 application image builds
  zones/internet/docker-compose.yml            application image builds
  infrastructure/clab-up.sh                    creates host bridges + clab deploy
  infrastructure/clab-down.sh                  reverses clab-up.sh
  infrastructure/routers/generated/*-acl.sh    per-router iptables ACL scripts

The compose files build images only; clab brings the containers up from the
per-zone topologies under clab/.

Usage:
    python orchestrator/generate.py [ctf-config.yaml]
"""

import os
import sys
import re
import logging
import subprocess
import yaml
from pathlib import Path

logging.basicConfig(level=logging.INFO, format="%(levelname)s - %(message)s")

REPO_ROOT = Path(__file__).resolve().parent.parent
ORCHESTRATOR_DIR = Path(__file__).resolve().parent
ZONES_DIR = REPO_ROOT / "zones"
INFRA_DIR = REPO_ROOT / "infrastructure"
ADVERSARY_README = ORCHESTRATOR_DIR / "adversary-readme.txt"
ROUTERS_DIR = INFRA_DIR / "routers"

# Maps implementation names to the directory containing their Dockerfile.
# Adding a new component variant means adding an entry here and a Dockerfile.
COMPONENT_DIRS = {
    # internet zone
    "admin-home":              ZONES_DIR / "internet" / "components" / "admin-home",
    # enterprise zone
    "win95-era":               ZONES_DIR / "enterprise" / "components" / "legacy-workstation",
    "enterprise-generic":      ZONES_DIR / "enterprise" / "components" / "enterprise-workstation",
    # operational zone
    "historian-v1":            ZONES_DIR / "operational" / "components" / "historian",
    "scada-generic":           ZONES_DIR / "operational" / "components" / "scada-server",
    "scada-lts":               ZONES_DIR / "operational" / "components" / "scada-lts",
    "engineering-workstation-generic": ZONES_DIR / "operational" / "components" / "engineering-workstation",
    # control zone devices
    "turbine-plc":             ZONES_DIR / "control" / "components" / "turbine-plc",
    "ied-relay":               ZONES_DIR / "control" / "components" / "ied-relay",
    "ied-meter":               ZONES_DIR / "control" / "components" / "ied-meter",
    "hmi":                     ZONES_DIR / "control" / "components" / "hmi",
    "actuator":                ZONES_DIR / "control" / "components" / "actuator",
    "actuator-modbus-sim":     ZONES_DIR / "control" / "components" / "actuator-modbus-sim",
    "mosquitto-broker":        ZONES_DIR / "control" / "components" / "mosquitto-broker",
    "stunnel-gateway":         ZONES_DIR / "control" / "components" / "stunnel-gateway",
    "scada-lts-ctrl":          ZONES_DIR / "control" / "components" / "scada-lts-ctrl",
    "fuxa":                    ZONES_DIR / "control" / "components" / "fuxa",
    "opcua-sidecar":           ZONES_DIR / "control" / "components" / "opcua-sidecar",
    # field devices (deferred, vendor-specific builds)
    # dmz zone
    "umati-gateway":    ZONES_DIR / "dmz" / "components" / "umati-gateway",
    "neuron-gateway":   ZONES_DIR / "dmz" / "components" / "neuron-gateway",
    "mqtt-dmz":         ZONES_DIR / "dmz" / "components" / "mqtt-dmz",
    "opcua-server":     ZONES_DIR / "dmz" / "components" / "opcua-server",
    "iec104-rtu":       ZONES_DIR / "dmz" / "components" / "iec104-rtu",
    "ssh-bastion-vuln": ZONES_DIR / "dmz" / "components" / "ssh-bastion",
    "sftp-drop":        ZONES_DIR / "dmz" / "components" / "sftp-drop",
    "ntp-server":       ZONES_DIR / "dmz" / "components" / "ntp-server",
    "dns-forwarder":    ZONES_DIR / "dmz" / "components" / "dns-forwarder",
    "syslog-relay":     ZONES_DIR / "dmz" / "components" / "syslog-relay",
}


# ---------------------------------------------------------------------------
# Config loading
# ---------------------------------------------------------------------------

def load_config(config_path: Path) -> dict:
    with open(config_path) as f:
        raw = f.read()
    # First pass: parse to get values for template resolution
    partial = yaml.safe_load(raw)
    # Second pass: resolve {{ key.path }} references, then re-parse
    rendered = _render_templates(raw, partial)
    return yaml.safe_load(rendered)


def _render_templates(text: str, config: dict) -> str:
    """Replace {{ dotted.key.path }} references with resolved values from config."""
    def resolve(match):
        path = match.group(1).strip().split(".")
        val = config
        for key in path:
            if isinstance(val, dict) and key in val:
                val = val[key]
            else:
                return match.group(0)  # leave unresolved rather than fail
        return str(val)
    return re.sub(r"\{\{([^}]+)\}\}", resolve, text)


# ---------------------------------------------------------------------------
# Path helpers
# ---------------------------------------------------------------------------

def _rel(abs_path, base_dir: Path) -> str:
    """Relative path from base_dir to abs_path."""
    return os.path.relpath(str(abs_path), str(base_dir))


def _relativize_services(services: dict, base_dir: Path, resolve_base: Path = None) -> None:
    """Convert build contexts and bind-mount host paths to relative to base_dir.

    If resolve_base is given, existing relative paths are resolved against it
    before being made relative to base_dir, enabling re-relativization from
    one base directory to another.
    """
    def _fix(path_str: str) -> str:
        if not os.path.isabs(path_str):
            if resolve_base is None:
                return path_str
            path_str = str((resolve_base / path_str).resolve())
        return _rel(path_str, base_dir)

    for svc in services.values():
        # build: "/abs/path"  or  build: {context: "/abs/path"}
        if isinstance(svc.get("build"), str):
            svc["build"] = _fix(svc["build"])
        elif isinstance(svc.get("build"), dict) and "context" in svc["build"]:
            svc["build"]["context"] = _fix(svc["build"]["context"])
        # volumes: ["host_path:container_path", ...]
        fixed = []
        for vol in svc.get("volumes", []):
            if isinstance(vol, str) and ":" in vol:
                host, rest = vol.split(":", 1)
                fixed.append(f"{_fix(host)}:{rest}")
            else:
                fixed.append(vol)
        if fixed:
            svc["volumes"] = fixed


# ---------------------------------------------------------------------------
# Network helpers
# ---------------------------------------------------------------------------

def _net(config: dict, key: str) -> str:
    return config["networks"][key]["docker_name"]


def _subnet(config: dict, key: str) -> str:
    return config["networks"][key]["subnet"]


def _external_net(name: str) -> dict:
    return {"external": True, "name": name}


# Each clab zone runs from clab/<zone>-zone.clab.yaml. Application services
# are still built via the per-zone docker-compose.yml files (compose stays
# the build tool); they are never started by compose. Routers come from
# clab/frr/ and the per-zone topology's bind to /acl.sh.
_CLAB_ZONES = ("internet", "enterprise", "operational", "control", "dmz")


# ---------------------------------------------------------------------------
# Enterprise zone
# ---------------------------------------------------------------------------

def generate_enterprise_compose(config: dict, output_path: Path) -> dict:
    ez = config["enterprise_zone"]
    ent_net = _net(config, "enterprise")
    ops_net = _net(config, "operational")
    base_dir = output_path.parent
    services = {}

    # Legacy workstation, enterprise network only.
    # Runs its own services as-built; attack surface is a property of the
    # implementation, not of this config.
    lw = ez["legacy_workstation"]
    _check_impl(lw["implementation"])
    services["legacy-workstation"] = {
        "build": {"context": _rel(COMPONENT_DIRS[lw["implementation"]], base_dir)},
        "container_name": "legacy-workstation",
        "hostname": lw["hostname"],
        "restart": "unless-stopped",
        "networks": {ent_net: {"ipv4_address": lw["ip"]}},
        "cap_add": ["NET_ADMIN"],
    }

    # Enterprise workstation, sits on enterprise AND operational networks.
    # This is the IT/OT convergence point. Dual-homed by design (or rather,
    # by the gradual accumulation of "temporary" network access never revoked).
    ew = ez["enterprise_workstation"]
    _check_impl(ew["implementation"])
    services["enterprise-workstation"] = {
        "build": {"context": _rel(COMPONENT_DIRS[ew["implementation"]], base_dir)},
        "container_name": "enterprise-workstation",
        "hostname": ew["hostname"],
        "restart": "unless-stopped",
        "networks": {
            ent_net: {"ipv4_address": ew["ip"]},
            ops_net: {"ipv4_address": ew["ops_ip"]},
        },
        "cap_add": ["NET_ADMIN"],
    }

    return {
        "services": services,
        "networks": {
            ent_net: _external_net(ent_net),
            ops_net: _external_net(ops_net),
        },
    }


# ---------------------------------------------------------------------------
# TLS certificate generation (for stunnel-gateway / scada-lts)
# ---------------------------------------------------------------------------

def generate_certs(repo_root: Path) -> Path:
    """Generate CA, server, and client certs in <repo_root>/certs/.

    Certs are NOT committed to the repo (.gitignore excludes certs/).
    Anyone who runs generate.py gets fresh certs. Containers mount them
    as read-only volumes; the client key is intentionally chmod 644 by
    the scada-lts entrypoint (CTF vulnerability HEX-5103).

    Returns the certs/ directory path.
    """
    certs_dir = repo_root / "certs"
    ca_key  = certs_dir / "ca.key"
    ca_crt  = certs_dir / "ca.crt"
    srv_key = certs_dir / "server.key"
    srv_crt = certs_dir / "server.crt"
    cli_key = certs_dir / "client.key"
    cli_crt = certs_dir / "client.crt"

    if all(p.exists() for p in [ca_crt, srv_crt, cli_crt]):
        logging.info("Certs already exist, skipping generation.")
        return certs_dir

    certs_dir.mkdir(exist_ok=True)

    subj_ca  = "/CN=UUPL-ModbusCA/O=Unseen University Power and Light Co/C=AM"
    subj_srv = "/CN=uupl-modbus-gw/O=Unseen University Power and Light Co/C=AM"
    subj_cli = "/CN=scadalts-client/O=Unseen University Power and Light Co/C=AM"

    def run(args):
        subprocess.run(args, check=True, capture_output=True)

    logging.info("Generating TLS certs in certs/ ...")

    # CA
    run(["openssl", "genrsa", "-out", str(ca_key), "2048"])
    run(["openssl", "req", "-new", "-x509", "-days", "3650",
         "-key", str(ca_key), "-out", str(ca_crt), "-subj", subj_ca])

    # Server cert (stunnel-gateway)
    srv_csr = certs_dir / "server.csr"
    run(["openssl", "genrsa", "-out", str(srv_key), "2048"])
    run(["openssl", "req", "-new", "-key", str(srv_key),
         "-out", str(srv_csr), "-subj", subj_srv])
    run(["openssl", "x509", "-req", "-days", "730",
         "-in", str(srv_csr), "-CA", str(ca_crt), "-CAkey", str(ca_key),
         "-CAcreateserial", "-out", str(srv_crt)])
    srv_csr.unlink()

    # Client cert (scada-lts)
    cli_csr = certs_dir / "client.csr"
    run(["openssl", "genrsa", "-out", str(cli_key), "2048"])
    run(["openssl", "req", "-new", "-key", str(cli_key),
         "-out", str(cli_csr), "-subj", subj_cli])
    run(["openssl", "x509", "-req", "-days", "3650",
         "-in", str(cli_csr), "-CA", str(ca_crt), "-CAkey", str(ca_key),
         "-CAcreateserial", "-out", str(cli_crt)])
    cli_csr.unlink()

    # Restrict key permissions (gateway entrypoint will chmod server.key; client
    # entrypoint intentionally widens client.key to 644 as the CTF vulnerability)
    srv_key.chmod(0o600)
    cli_key.chmod(0o600)

    logging.info(f"Certs written to {certs_dir}")
    return certs_dir


# ---------------------------------------------------------------------------
# Operational zone
# ---------------------------------------------------------------------------

def generate_operational_compose(config: dict, output_path: Path) -> dict:
    oz = config["operational_zone"]
    ops_net = _net(config, "operational")
    ctrl_net = _net(config, "control")
    base_dir = output_path.parent
    certs_dir = REPO_ROOT / "certs"
    services = {}
    named_volumes = {}

    # Historian, operational network only, reachable from enterprise-workstation
    # via its dual-homed ops_ip.
    hist = oz["historian"]
    _check_impl(hist["implementation"])
    services["historian"] = {
        "build": {"context": _rel(COMPONENT_DIRS[hist["implementation"]], base_dir)},
        "container_name": "historian",
        "hostname": hist["hostname"],
        "restart": "unless-stopped",
        "networks": {ops_net: {"ipv4_address": hist["ip"]}},
        "cap_add": ["NET_ADMIN"],
        "environment": {
            # Tells the historian which ICS process data to seed at startup.
            # Affects what time-series data is available and what queries return.
            "DATA_SOURCE": hist.get("data_source", config["ics_process"]),
        },
    }

    # SCADA server.
    # scada-lts: Scada-LTS (Mango-based) with stunnel Modbus-TLS client.
    #   Requires a MySQL sidecar (scada-db). Certs volume-mounted from certs/.
    # scada-generic: custom Flask SCADA (original implementation).
    scada = oz["scada_server"]
    _check_impl(scada["implementation"])

    if scada["implementation"] == "scada-lts":
        # MySQL sidecar, backing database for Scada-LTS.
        # Weak credentials (scadalts/scada2015) are discoverable via SQLi or
        # credential dump once the SCADA is compromised.
        named_volumes["scada-db-data"] = {}
        services["scada-db"] = {
            "image": "mysql:8",
            "container_name": "scada-db",
            "hostname": "scada-db",
            "restart": "unless-stopped",
            "networks": {ops_net: {"ipv4_address": "10.10.2.19"}},
            "environment": {
                "MYSQL_DATABASE":      "scadalts",
                "MYSQL_USER":          "scadalts",
                "MYSQL_PASSWORD":      "scada2015",
                "MYSQL_ROOT_PASSWORD": "scadaroot",
            },
            "volumes": ["scada-db-data:/var/lib/mysql"],
        }
        gw_ops_ip = oz.get("stunnel_gateway", {}).get("ops_ip", "10.10.2.50")
        scada_svc = {
            "build": {"context": _rel(COMPONENT_DIRS[scada["implementation"]], base_dir)},
            "container_name": "scada-server",
            "hostname": scada["hostname"],
            "restart": "unless-stopped",
            "networks": {ops_net: {"ipv4_address": scada["ip"]}},
            "cap_add": ["NET_ADMIN"],
            "environment": {
                "MYSQL_HOST":     "scada-db",
                "MYSQL_PORT":     "3306",
                "MYSQL_DATABASE": "scadalts",
                "MYSQL_USER":     "scadalts",
                "MYSQL_PASSWORD": "scada2015",
                "STUNNEL_GW_IP":  gw_ops_ip,
            },
            "depends_on": ["scada-db"],
            # Mount client cert + key from generated certs/ directory. The
            # mount is read-write so the entrypoint can chmod 644 client.key
            # at startup, which is HEX-5103 (engineers widened the perms so
            # the monitoring user could read it, then never tightened them).
            "volumes": [
                f"{_rel(certs_dir / 'client.crt', base_dir)}:/run/stunnel-certs/client.crt",
                f"{_rel(certs_dir / 'client.key', base_dir)}:/run/stunnel-certs/client.key",
                f"{_rel(certs_dir / 'ca.crt',     base_dir)}:/run/stunnel-certs/ca.crt",
            ],
        }
    else:
        scada_svc = {
            "build": {"context": _rel(COMPONENT_DIRS[scada["implementation"]], base_dir)},
            "container_name": "scada-server",
            "hostname": scada["hostname"],
            "restart": "unless-stopped",
            "networks": {ops_net: {"ipv4_address": scada["ip"]}},
            "cap_add": ["NET_ADMIN"],
            "environment": {
                "HISTORIAN_IP": scada.get("historian_ip", hist["ip"]),
            },
        }

    services["scada-server"] = scada_svc

    # stunnel-gateway, TLS termination proxy between SCADA and control zone PLCs.
    # Dual-homed: operational (accepts TLS from SCADA) + control (plain Modbus to PLC).
    # Only present when stunnel_gateway is defined in config.
    gw_cfg = oz.get("stunnel_gateway")
    if gw_cfg:
        _check_impl(gw_cfg["implementation"])
        gw_component = COMPONENT_DIRS[gw_cfg["implementation"]]
        services["stunnel-gateway"] = {
            "build": {"context": _rel(gw_component, base_dir)},
            "container_name": "stunnel-gateway",
            "hostname": gw_cfg["hostname"],
            "restart": "unless-stopped",
            "cap_add": ["NET_ADMIN"],
            "networks": {
                ops_net:  {"ipv4_address": gw_cfg["ops_ip"]},
                ctrl_net: {"ipv4_address": gw_cfg["ctrl_ip"]},
            },
            "environment": {
                "FORWARD_TARGET": gw_cfg.get("forward_to", "10.10.3.21:502"),
            },
            # Mount stunnel.conf template and certs from generated certs/ directory.
            "volumes": [
                f"{_rel(gw_component / 'stunnel.conf',  base_dir)}:/run/stunnel/stunnel.conf:ro",
                f"{_rel(certs_dir / 'ca.crt',           base_dir)}:/run/stunnel/ca.crt:ro",
                f"{_rel(certs_dir / 'server.crt',       base_dir)}:/run/stunnel/server.crt:ro",
                f"{_rel(certs_dir / 'server.key',       base_dir)}:/run/stunnel/server.key:ro",
            ],
        }

    # Engineering workstation, sits on BOTH operational AND control networks.
    # The pivot point into the control zone.
    eng = oz["engineering_workstation"]
    _check_impl(eng["implementation"])
    services["engineering-workstation"] = {
        "build": {"context": _rel(COMPONENT_DIRS[eng["implementation"]], base_dir)},
        "container_name": "engineering-workstation",
        "hostname": eng["hostname"],
        "restart": "unless-stopped",
        "networks": {
            ops_net: {"ipv4_address": eng["ip"]},
            ctrl_net: {"ipv4_address": eng["ctrl_ip"]},
        },
        "environment": {
            # ICS_PROCESS and CONTROL_SUBNET drive what the engineering-workstation
            # has configured: which device IPs are in its config files, what
            # tools are set up, etc.
            "ICS_PROCESS":      eng.get("ics_process", config["ics_process"]),
            "CONTROL_SUBNET":   eng.get("control_network_subnet", _subnet(config, "control")),
        },
        "cap_add": ["NET_ADMIN"],
    }

    compose = {
        "services": services,
        "networks": {
            ops_net:  _external_net(ops_net),
            ctrl_net: _external_net(ctrl_net),
        },
    }
    if named_volumes:
        compose["volumes"] = named_volumes
    return compose


# ---------------------------------------------------------------------------
# Control zone (native, no external simulator dependency)
# ---------------------------------------------------------------------------

def generate_control_compose(config: dict, output_path: Path) -> dict:
    ctrl_net = _net(config, "control")
    base_dir = output_path.parent
    certs_dir = REPO_ROOT / "certs"
    services = {}
    named_volumes = {}

    # Resolve stunnel gateway ctrl IP for scada-lts-ctrl instances.
    gw_ctrl_ip = (
        config.get("operational_zone", {})
              .get("stunnel_gateway", {})
              .get("ctrl_ip", "10.10.3.50")
    )

    for dev in config.get("control_zone", {}).get("devices", []):
        impl = dev["implementation"]
        _check_impl(impl)
        svc_name = dev["name"].replace("_", "-")

        if impl == "scada-lts-ctrl":
            # MySQL sidecar, backing database for the control-zone Scada-LTS.
            db_ip = "10.10.3.11"
            db_svc = f"{dev['name']}-db"
            named_volumes[f"{dev['name']}-db-data"] = {}
            services[db_svc] = {
                "image": "mysql:8",
                "container_name": db_svc,
                "hostname": db_svc,
                "restart": "unless-stopped",
                "networks": {ctrl_net: {"ipv4_address": db_ip}},
                "environment": {
                    "MYSQL_DATABASE":      "scadalts",
                    "MYSQL_USER":          "scadalts",
                    "MYSQL_PASSWORD":      "scada2015",
                    "MYSQL_ROOT_PASSWORD": "scadaroot",
                },
                "volumes": [f"{dev['name']}-db-data:/var/lib/mysql"],
            }
            svc = {
                "build": {"context": _rel(COMPONENT_DIRS[impl], base_dir)},
                "container_name": dev["name"],
                "hostname": dev.get("hostname", dev["name"]),
                "restart": "unless-stopped",
                "networks": {ctrl_net: {"ipv4_address": dev["ip"]}},
                "environment": {
                    "MYSQL_HOST":     db_svc,
                    "MYSQL_PORT":     "3306",
                    "MYSQL_DATABASE": "scadalts",
                    "MYSQL_USER":     "scadalts",
                    "MYSQL_PASSWORD": "scada2015",
                    "STUNNEL_GW_IP":  gw_ctrl_ip,
                    **(dev.get("env") or {}),
                },
                "depends_on": [db_svc],
                "volumes": [
                    f"{_rel(certs_dir / 'client.crt', base_dir)}:/run/stunnel-certs/client.crt",
                    f"{_rel(certs_dir / 'client.key', base_dir)}:/run/stunnel-certs/client.key",
                    f"{_rel(certs_dir / 'ca.crt',     base_dir)}:/run/stunnel-certs/ca.crt",
                ],
            }
        else:
            svc = {
                "build": {"context": _rel(COMPONENT_DIRS[impl], base_dir)},
                "container_name": dev["name"],
                "hostname": dev.get("hostname", dev["name"]),
                "restart": "unless-stopped",
                "cap_add": ["NET_ADMIN"],
                "networks": {ctrl_net: {"ipv4_address": dev["ip"]}},
            }
            if dev.get("env"):
                svc["environment"] = dev["env"]

        services[svc_name] = svc

        # Sidecars: share parent network namespace (no ip) or get their own IP.
        for sidecar in dev.get("sidecars", []):
            sc_impl = sidecar["implementation"]
            _check_impl(sc_impl)
            sc_name = sidecar["name"].replace("_", "-")
            sc_svc = {
                "build": {"context": _rel(COMPONENT_DIRS[sc_impl], base_dir)},
                "container_name": sidecar["name"],
                "restart": "unless-stopped",
            }
            if "ip" in sidecar:
                sc_svc["hostname"] = sidecar.get("hostname", sidecar["name"])
                sc_svc["networks"] = {ctrl_net: {"ipv4_address": sidecar["ip"]}}
            else:
                sc_svc["network_mode"] = f"service:{svc_name}"
                sc_svc["depends_on"] = [svc_name]
            if sidecar.get("env"):
                sc_svc["environment"] = sidecar["env"]
            services[sc_name] = sc_svc

    compose = {
        "services": services,
        "networks": {ctrl_net: _external_net(ctrl_net)},
    }
    if named_volumes:
        compose["volumes"] = named_volumes
    return compose


# ---------------------------------------------------------------------------
# DMZ zone
# ---------------------------------------------------------------------------

def generate_dmz_compose(config: dict, output_path: Path) -> dict:
    """Generate zones/dmz/docker-compose.yml.

    Iterates dmz_zone.devices. Devices with an enterprise_ip are dual-homed
    on both ics_dmz and ics_enterprise (simulates contractor pivot path).
    """
    dmz_net = _net(config, "dmz")
    ent_net = _net(config, "enterprise")
    base_dir = output_path.parent
    services = {}
    networks_used = {dmz_net}

    for dev in config.get("dmz_zone", {}).get("devices", []):
        impl = dev["implementation"]
        _check_impl(impl)
        svc_name = dev["name"].replace("_", "-")

        networks = {dmz_net: {"ipv4_address": dev["ip"]}}
        if "enterprise_ip" in dev:
            networks[ent_net] = {"ipv4_address": dev["enterprise_ip"]}
            networks_used.add(ent_net)

        svc = {
            "build": {"context": _rel(COMPONENT_DIRS[impl], base_dir)},
            "container_name": dev["name"],
            "hostname": dev.get("hostname", dev["name"]),
            "restart": "unless-stopped",
            "cap_add": ["NET_ADMIN"],
            "networks": networks,
        }
        if dev.get("env"):
            svc["environment"] = dev["env"]

        if dev.get("syslog_logging"):
            svc["logging"] = {
                "driver": "syslog",
                "options": {
                    "syslog-address": "udp://10.10.5.32:514",
                    "tag": dev.get("hostname", dev["name"]),
                },
            }
            svc.setdefault("depends_on", []).append("syslog-relay")

        services[svc_name] = svc

    return {
        "services": services,
        "networks": {n: _external_net(n) for n in networks_used},
    }


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _check_impl(name: str) -> None:
    if name not in COMPONENT_DIRS:
        raise ValueError(
            f"Unknown implementation/vendor: {name!r}. "
            f"Known: {list(COMPONENT_DIRS)}"
        )


def write_compose(path: Path, compose_dict: dict) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with open(path, "w") as f:
        yaml.dump(compose_dict, f, sort_keys=False, default_flow_style=False)
    logging.info(f"Wrote: {path}")


def write_text(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    logging.info(f"Wrote: {path}")


# ---------------------------------------------------------------------------
# Internet zone (admin-home and any future internet-facing infrastructure)
# ---------------------------------------------------------------------------

def generate_internet_zone_compose(config: dict, output_path: Path) -> dict:
    """Generate zones/internet/docker-compose.yml.

    Contains all internet-zone nodes: attacker machine (unseen-gate) and any
    additional nodes defined in internet_zone (admin_home, future DMZ pivot, etc.).
    """
    inet_net = _net(config, "internet")
    ent_net  = _net(config, "enterprise")
    ops_net  = _net(config, "operational")
    base_dir = output_path.parent
    services = {}
    networks_used = {inet_net}

    # Attacker machine, always present (defined under attacker_machine in config)
    jh = config["attacker_machine"]
    ssh_host_port = jh.get("ssh_host_port", 22)
    auth_mode = jh.get("auth_mode", "key")
    attacker_dir = ZONES_DIR / "internet" / "components" / "attacker-machine"
    attacker_rel = _rel(attacker_dir, base_dir)

    svc = {
        "build": {"context": attacker_rel},
        "container_name": "attacker-machine",
        "hostname": jh["hostname"],
        "restart": "unless-stopped",
        "networks": {inet_net: {"ipv4_address": jh["internet_ip"]}},
        "ports": [f"{ssh_host_port}:22"],
        # adversary-readme is useful in both modes (mission briefing)
        "volumes": [f"./{attacker_rel}/adversary-readme.txt:/run/adversary-readme.txt:ro"],
    }

    if auth_mode == "password":
        # Password mode: set credentials from config, no key file needed.
        # Used for Root-Me and platforms that publish connection strings.
        accounts = jh.get("accounts", {})
        account_str = " ".join(f"{u}:{p}" for u, p in accounts.items())
        svc["environment"] = {
            "AUTH_MODE": "password",
            "AUTH_ACCOUNTS": account_str,
        }
    else:
        # Key mode (default): pubkey auth, keys mounted at runtime.
        # Used for self-hosted / Hetzner deployments.
        svc["volumes"].insert(
            0, f"./{attacker_rel}/adversary-keys:/run/adversary-keys:ro"
        )

    svc["privileged"] = True  # required to issue mount(2) from inside the container
    services["attacker-machine"] = svc

    # Additional internet-zone nodes (admin_home, etc.)
    iz = config.get("internet_zone", {})
    ah = iz.get("admin_home")
    if ah:
        _check_impl(ah["implementation"])
        ah_networks = {
            inet_net: {"ipv4_address": ah["internet_ip"]},
            ent_net:  {"ipv4_address": ah["enterprise_ip"]},
        }
        if "operational_ip" in ah:
            ah_networks[ops_net] = {"ipv4_address": ah["operational_ip"]}
            networks_used.add(ops_net)
        services["admin-home"] = {
            "build": {"context": _rel(COMPONENT_DIRS[ah["implementation"]], base_dir)},
            "container_name": "admin-home",
            "hostname": ah["hostname"],
            "restart": "unless-stopped",
            "privileged": True,  # tmpfs mount inside container (OverlayFS has no name_to_handle_at)
            "networks": ah_networks,
        }
        networks_used.add(ent_net)
        # attacker-machine (NFS client) must stop before admin-home (NFS server).
        # Compose down reverses depends_on order, so declaring attacker depends on
        # admin-home means attacker stops first.
        services["attacker-machine"]["depends_on"] = ["admin-home"]

    return {
        "services": services,
        "networks": {n: _external_net(n) for n in networks_used},
    }


# ---------------------------------------------------------------------------
# Attacker machine
# ---------------------------------------------------------------------------

def generate_adversary_readme(config: dict) -> str:
    addrs = {
        "enterprise_subnet": config["networks"]["enterprise"]["subnet"],
        "legacy_ws_ip":      config["enterprise_zone"]["legacy_workstation"]["ip"],
        "ent_ws_ip":         config["enterprise_zone"]["enterprise_workstation"]["ip"],
    }
    return ADVERSARY_README.read_text().format_map(addrs)


def generate_jump_host_compose(config: dict, output_path: Path) -> dict:
    inet_net = _net(config, "internet")
    jh = config["attacker_machine"]
    ssh_host_port = jh.get("ssh_host_port", 22)
    return {
        "services": {
            "attacker-machine": {
                "build": {"context": "."},   # relative to compose file dir
                "container_name": "attacker-machine",
                "hostname": jh["hostname"],
                "restart": "unless-stopped",
                "networks": {
                    inet_net: {"ipv4_address": jh["internet_ip"]},
                },
                "ports": [f"{ssh_host_port}:22"],
                "volumes": [
                    "./adversary-keys:/run/adversary-keys:ro",
                    "./adversary-readme.txt:/run/adversary-readme.txt:ro",
                ],
            }
        },
        "networks": {
            inet_net: _external_net(inet_net),
        },
    }


# ---------------------------------------------------------------------------
# Zone routers
# ---------------------------------------------------------------------------

def _router_ip(subnet: str, host: int) -> str:
    """Derive a host address from a /24 subnet (e.g. 10.10.0.0/24 + 200 → 10.10.0.200)."""
    prefix = subnet.split("/")[0].rsplit(".", 1)[0]
    return f"{prefix}.{host}"


def generate_routers(config: dict) -> None:
    """Generate infrastructure/routers/generated/.

    Produces:
      docker-compose.yml , five router services, each dual-homed on two zone networks
      <name>-acl.sh      , per-router iptables FORWARD policy + static transit routes

    Router IP convention: .200-series host addresses within each zone.
      inet-dmz-fw:    internet .200,  dmz .200
      dmz-ent-fw:     dmz .201,       enterprise .201
      ent-ops-fw:     enterprise .202, operational .202
      ops-ctrl-fw:    operational .203, control .203
      ops-wan-router: operational .204, wan .204

    The Dockerfile and entrypoint.sh in infrastructure/routers/ are static (committed).
    Only the generated/ subdirectory changes per config.
    """
    nets = config["networks"]
    out  = ROUTERS_DIR / "generated"
    out.mkdir(parents=True, exist_ok=True)

    def subnet(key):  return nets[key]["subnet"]
    def netname(key): return nets[key]["docker_name"]
    def rip(key, h):  return _router_ip(subnet(key), h)

    # Resolved addresses used across ACL scripts
    historian = config["operational_zone"]["historian"]["ip"]
    scada     = config["operational_zone"]["scada_server"]["ip"]
    eng_ws    = config["operational_zone"]["engineering_workstation"]["ip"]
    ssh_bastion = next(
        (d["ip"] for d in config.get("dmz_zone", {}).get("devices", [])
         if d.get("implementation") == "ssh-bastion-vuln"),
        "0.0.0.0/32"
    )

    # ── ACL scripts ──────────────────────────────────────────────────────────

    # inet-dmz-fw: internet ↔ dmz
    # Routes all internet→dmz traffic via dmz-ent-fw for symmetric conntrack.
    (out / "inet-dmz-fw-acl.sh").write_text(
        f"#!/usr/bin/env sh\n"
        f"# inet-dmz-fw: {netname('internet')} {rip('internet',200)} "
        f"<-> {netname('dmz')} {rip('dmz',200)}\n\n"
        f"# Forward all dmz-destined traffic through dmz-ent-fw so conntrack\n"
        f"# sees both directions (symmetric routing).\n"
        f"ip route replace {subnet('dmz')} via {rip('dmz',201)} 2>/dev/null || true\n\n"
        f"iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n"
        f"# Internet → DMZ: open (externally-facing attack surface)\n"
        f"iptables -A FORWARD -s {subnet('internet')} -d {subnet('dmz')} -j ACCEPT\n"
    )

    # dmz-ent-fw: dmz ↔ enterprise
    # Acts as the central DMZ hub: routes internet↔dmz, dmz↔operational, eng-ws↔dmz.
    (out / "dmz-ent-fw-acl.sh").write_text(
        f"#!/usr/bin/env sh\n"
        f"# dmz-ent-fw: {netname('dmz')} {rip('dmz',201)} "
        f"<-> {netname('enterprise')} {rip('enterprise',201)}\n\n"
        f"# Transit routes for non-adjacent zones\n"
        f"ip route replace {subnet('internet')} via {rip('dmz',200)} 2>/dev/null || true\n"
        f"ip route replace {subnet('operational')} via {rip('enterprise',202)} 2>/dev/null || true\n\n"
        f"iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n"
        f"# Internet ↔ DMZ (conntrack-symmetric via inet-dmz-fw)\n"
        f"iptables -A FORWARD -s {subnet('internet')} -d {subnet('dmz')} -j ACCEPT\n"
        f"iptables -A FORWARD -s {subnet('dmz')} -d {subnet('internet')} -j ACCEPT\n"
        f"# DMZ → operational historian/scada (data broker read access)\n"
        f"iptables -A FORWARD -s {subnet('dmz')} -d {historian} -p tcp --dport 8080 -j ACCEPT\n"
        f"iptables -A FORWARD -s {subnet('dmz')} -d {scada}     -p tcp --dport 8080 -j ACCEPT\n"
        f"# Operational eng-ws → DMZ (CTF lateral movement path)\n"
        f"iptables -A FORWARD -s {eng_ws} -d {subnet('dmz')} -j ACCEPT\n"
        f"# ssh-bastion → enterprise (contractor pivot, bastion is dual-homed so\n"
        f"# it routes directly; this rule covers any traffic that transits here)\n"
        f"iptables -A FORWARD -s {ssh_bastion} -d {subnet('enterprise')} -j ACCEPT\n"
        f"# All else: DROP (default policy)\n"
    )

    # ent-ops-fw: enterprise ↔ operational
    (out / "ent-ops-fw-acl.sh").write_text(
        f"#!/usr/bin/env sh\n"
        f"# ent-ops-fw: {netname('enterprise')} {rip('enterprise',202)} "
        f"<-> {netname('operational')} {rip('operational',202)}\n\n"
        f"# Transit routes for non-adjacent zones\n"
        f"ip route replace {subnet('dmz')} via {rip('enterprise',201)} 2>/dev/null || true\n"
        f"ip route replace {subnet('control')} via {rip('operational',203)} 2>/dev/null || true\n"
        f"ip route replace {subnet('wan')} via {rip('operational',204)} 2>/dev/null || true\n\n"
        f"iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n"
        f"# Enterprise → operational: web UIs and SSH to engineering workstation\n"
        f"iptables -A FORWARD -s {subnet('enterprise')} -d {historian} -p tcp --dport 8080 -j ACCEPT\n"
        f"iptables -A FORWARD -s {subnet('enterprise')} -d {scada}     -p tcp --dport 8080 -j ACCEPT\n"
        f"iptables -A FORWARD -s {subnet('enterprise')} -d {eng_ws}    -p tcp --dport 22   -j ACCEPT\n"
        f"# DMZ → operational historian/scada (transiting enterprise)\n"
        f"iptables -A FORWARD -s {subnet('dmz')} -d {historian} -p tcp --dport 8080 -j ACCEPT\n"
        f"iptables -A FORWARD -s {subnet('dmz')} -d {scada}     -p tcp --dport 8080 -j ACCEPT\n"
        f"# Operational eng-ws → DMZ (transiting enterprise outbound)\n"
        f"iptables -A FORWARD -s {eng_ws} -d {subnet('dmz')} -j ACCEPT\n"
        f"# Operational → enterprise: DROP (OT does not initiate enterprise connections)\n"
        f"iptables -A FORWARD -s {subnet('operational')} -d {subnet('enterprise')} -j DROP\n"
        f"# All else: DROP (default policy)\n"
    )

    # ops-ctrl-fw: operational ↔ control
    (out / "ops-ctrl-fw-acl.sh").write_text(
        f"#!/usr/bin/env sh\n"
        f"# ops-ctrl-fw: {netname('operational')} {rip('operational',203)} "
        f"<-> {netname('control')} {rip('control',203)}\n\n"
        f"iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n"
        f"# Operational eng-ws → control zone: Modbus only\n"
        f"iptables -A FORWARD -s {eng_ws} -d {subnet('control')} -p tcp --dport 502 -j ACCEPT\n"
        f"# Control → operational: DROP (control devices do not initiate connections)\n"
        f"iptables -A FORWARD -s {subnet('control')} -d {subnet('operational')} -j DROP\n"
        f"# All else: DROP (default policy)\n"
    )

    # ops-wan-router: operational ↔ wan
    (out / "ops-wan-router-acl.sh").write_text(
        f"#!/usr/bin/env sh\n"
        f"# ops-wan-router: {netname('operational')} {rip('operational',204)} "
        f"<-> {netname('wan')} {rip('wan',204)}\n\n"
        f"iptables -A FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT\n"
        f"# Operational SCADA + eng-ws → WAN RTUs: Modbus TCP and SNMP\n"
        f"iptables -A FORWARD -s {scada}  -d {subnet('wan')} -p tcp --dport 502 -j ACCEPT\n"
        f"iptables -A FORWARD -s {eng_ws} -d {subnet('wan')} -p tcp --dport 502 -j ACCEPT\n"
        f"iptables -A FORWARD -s {scada}  -d {subnet('wan')} -p udp --dport 161 -j ACCEPT\n"
        f"iptables -A FORWARD -s {eng_ws} -d {subnet('wan')} -p udp --dport 161 -j ACCEPT\n"
        f"# WAN → operational: DROP (RTUs do not initiate connections)\n"
        f"iptables -A FORWARD -s {subnet('wan')} -d {subnet('operational')} -j DROP\n"
        f"# All else: DROP (default policy)\n"
    )

    # Make ACL scripts executable; clab binds them as /acl.sh.
    for acl in out.glob("*-acl.sh"):
        acl.chmod(0o755)

    # The previous compose-managed router stack is retired. If a stale
    # docker-compose.yml lingers from an older generate run, drop it.
    compose_path = out / "docker-compose.yml"
    if compose_path.exists():
        compose_path.unlink()
    logging.info(f"Router ACL scripts written to {out}")


# ---------------------------------------------------------------------------
# Clab orchestration helpers
# ---------------------------------------------------------------------------
# The data plane is real Linux bridges referenced by every topology as
# kind: bridge nodes. Bridge lifecycle (create on up, delete on down)
# lives in these helpers so clab itself never owns them.

_CLAB_BRIDGES = ("ics_internet", "ics_enterprise", "ics_operational",
                 "ics_control", "ics_dmz", "ics_wan")


def generate_clab_helpers(config: dict) -> None:
    """Write infrastructure/clab-up.sh and clab-down.sh.

    up: pre-create the host Linux bridges with sudo, build the FRR image,
        deploy each per-zone topology in order.
    down: destroy each topology in reverse order, then drop the host
          bridges with sudo.
    """
    bridges = " ".join(_CLAB_BRIDGES)

    deploy = "\n".join(
        f'containerlab deploy --topo "$REPO/clab/{z}-zone.clab.yaml"'
        for z in _CLAB_ZONES
    )
    # Do not silence clab's stderr; the per-container "Removed container"
    # lines are how operators verify the teardown actually happened.
    destroy = "\n".join(
        f'containerlab destroy --topo "$REPO/clab/{z}-zone.clab.yaml"'
        for z in reversed(_CLAB_ZONES)
    )

    # Host-side plumbing for the SSH entry point. attacker-machine runs
    # with `network-mode: none` so its only interface is eth1 at
    # 10.10.0.5; docker port-publish would not work. Instead the host
    # gets 10.10.0.1/24 on the ics_internet bridge (looks like an
    # upstream gateway from the visitor's view) and DNATs host:2222 to
    # 10.10.0.5:22. INPUT-DROP keeps containers from reaching host
    # services through that bridge IP.
    nat_setup = (
        "ip addr show dev ics_internet | grep -q '10\\.10\\.0\\.1/24' "
        "|| ip addr add 10.10.0.1/24 dev ics_internet; "
        "iptables -C INPUT -i ics_internet -j DROP 2>/dev/null "
        "|| iptables -A INPUT -i ics_internet -j DROP; "
        "iptables -t nat -C PREROUTING -p tcp --dport 2222 -j DNAT --to-destination 10.10.0.5:22 2>/dev/null "
        "|| iptables -t nat -A PREROUTING -p tcp --dport 2222 -j DNAT --to-destination 10.10.0.5:22; "
        "iptables -t nat -C OUTPUT -p tcp --dport 2222 -j DNAT --to-destination 10.10.0.5:22 2>/dev/null "
        "|| iptables -t nat -A OUTPUT -p tcp --dport 2222 -j DNAT --to-destination 10.10.0.5:22; "
        "iptables -t nat -C POSTROUTING -d 10.10.0.5 -p tcp --dport 22 -j MASQUERADE 2>/dev/null "
        "|| iptables -t nat -A POSTROUTING -d 10.10.0.5 -p tcp --dport 22 -j MASQUERADE"
    )
    nat_teardown = (
        "iptables -t nat -D POSTROUTING -d 10.10.0.5 -p tcp --dport 22 -j MASQUERADE 2>/dev/null; "
        "iptables -t nat -D OUTPUT -p tcp --dport 2222 -j DNAT --to-destination 10.10.0.5:22 2>/dev/null; "
        "iptables -t nat -D PREROUTING -p tcp --dport 2222 -j DNAT --to-destination 10.10.0.5:22 2>/dev/null; "
        "iptables -D INPUT -i ics_internet -j DROP 2>/dev/null; "
        "ip addr flush dev ics_internet 2>/dev/null"
    )

    up = INFRA_DIR / "clab-up.sh"
    up.write_text(
        "#!/usr/bin/env bash\n"
        "# Generated by orchestrator/generate.py, do not edit directly.\n"
        "set -euo pipefail\n"
        'REPO="$(cd "$(dirname "$0")/.." && pwd)"\n\n'
        'echo "[clab] Creating host bridges + SSH NAT (sudo)..."\n'
        f"sudo bash -c '"
        f'for b in {bridges}; do '
        'ip link show "$b" >/dev/null 2>&1 || ip link add "$b" type bridge; '
        'ip link set "$b" up; '
        # STP on by default, realistic OT switch posture. BPDU guard is
        # intentionally absent: that is the attack surface (root takeover).
        'ip link set "$b" type bridge stp_state 1; '
        # IGMP snooping off so unsolicited multicast (OSPF Hello to
        # 224.0.0.5, etc.) floods between ports. With snooping on and no
        # IGMP querier the bridge drops it, breaking routing-protocol
        # adjacency. Realistic for an unmanaged OT switch.
        'ip link set "$b" type bridge mcast_snooping 0; '
        'done; '
        f"{nat_setup}'\n\n"
        'echo "[clab] Building clab-router image..."\n'
        'docker build -q -t clab-router "$REPO/clab/frr"\n\n'
        'echo "[clab] Building lab-mysql8 image..."\n'
        'docker build -q -t lab-mysql8 "$REPO/clab/lab-mysql8"\n\n'
        'echo "[clab] Deploying topologies..."\n'
        + deploy + "\n"
    )
    up.chmod(0o755)

    down = INFRA_DIR / "clab-down.sh"
    down.write_text(
        "#!/usr/bin/env bash\n"
        "# Generated by orchestrator/generate.py, do not edit directly.\n"
        "set +e\n"
        'REPO="$(cd "$(dirname "$0")/.." && pwd)"\n\n'
        'echo "[clab] Destroying topologies..."\n'
        + destroy + "\n\n"
        'echo "[clab] Removing SSH NAT + host bridges (sudo)..."\n'
        f"sudo bash -c '"
        f"{nat_teardown}; "
        f'for b in {bridges}; do '
        'ip link delete "$b" type bridge 2>/dev/null; done\'\n'
    )
    down.chmod(0o755)
    logging.info(f"Wrote: {up}")
    logging.info(f"Wrote: {down}")


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    config_path = (
        Path(sys.argv[1]) if len(sys.argv) > 1
        else ORCHESTRATOR_DIR / "ctf-config.yaml"
    )

    logging.info(f"Loading config: {config_path}")
    config = load_config(config_path)

    # Generate TLS certs if any zone uses stunnel-gateway or scada-lts.
    oz = config.get("operational_zone", {})
    ctrl_devices = config.get("control_zone", {}).get("devices", [])
    needs_certs = (
        oz.get("stunnel_gateway") or
        oz.get("scada_server", {}).get("implementation") == "scada-lts" or
        any(d["implementation"] == "scada-lts-ctrl" for d in ctrl_devices)
    )
    if needs_certs:
        generate_certs(REPO_ROOT)

    # The shared networks compose is gone: the data plane runs on real
    # Linux bridges created by infrastructure/clab-up.sh, not docker
    # user-defined networks. Drop the file if a previous generate left it.
    legacy_networks = INFRA_DIR / "networks" / "docker-compose.yml"
    if legacy_networks.exists():
        legacy_networks.unlink()

    enterprise_path  = ZONES_DIR / "enterprise"  / "docker-compose.yml"
    operational_path = ZONES_DIR / "operational" / "docker-compose.yml"
    control_path     = ZONES_DIR / "control"     / "docker-compose.yml"

    write_compose(enterprise_path,  generate_enterprise_compose(config, enterprise_path))
    write_compose(operational_path, generate_operational_compose(config, operational_path))
    write_compose(control_path,     generate_control_compose(config, control_path))

    internet_path = ZONES_DIR / "internet" / "docker-compose.yml"
    write_compose(internet_path, generate_internet_zone_compose(config, internet_path))
    write_text(ZONES_DIR / "internet" / "components" / "attacker-machine" / "adversary-readme.txt", generate_adversary_readme(config))

    if config.get("dmz_zone"):
        dmz_path = ZONES_DIR / "dmz" / "docker-compose.yml"
        write_compose(dmz_path, generate_dmz_compose(config, dmz_path))

    generate_routers(config)
    generate_clab_helpers(config)

    # Drop stale files left by previous generator iterations. firewall.sh was
    # the docker-bridge gateway-hiding workaround; .fabric was the per-zone
    # fabric-toggle marker; start.sh / stop.sh drove the old compose-only
    # zone start-up before clab-up.sh took over.
    for stale in (
        INFRA_DIR / "firewall.sh",
        INFRA_DIR / ".fabric",
        REPO_ROOT / "start.sh",
        REPO_ROOT / "stop.sh",
    ):
        if stale.exists():
            stale.unlink()

    logging.info("Done. Run: ./ctl up")


if __name__ == "__main__":
    main()
