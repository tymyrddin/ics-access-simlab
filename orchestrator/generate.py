#!/usr/bin/env python3
"""Generate the per-zone clab artefacts from ctf-config.yaml.

  zones/enterprise/docker-compose.yml          application image builds
  zones/operational/docker-compose.yml         application image builds
  zones/control/docker-compose.yml             application image builds (turbine PLC,
                                               HMI, IEDs, actuators)
  zones/dmz/docker-compose.yml                 application image builds
  zones/internet/docker-compose.yml            application image builds
  infrastructure/clab-up.sh                    creates host bridges + clab deploy
  infrastructure/clab-down.sh                  reverses clab-up.sh
  infrastructure/routers/generated/*-acl.sh    per-router iptables ACL scripts

Usage: python orchestrator/generate.py [ctf-config.yaml]
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
ZONES_DIR = REPO_ROOT / 'zones'
INFRA_DIR = REPO_ROOT / "infrastructure"
ADVERSARY_README = ORCHESTRATOR_DIR / 'adversary-readme.txt'
ROUTERS_DIR = INFRA_DIR / 'routers'

COMPONENT_DIRS = {
    # internet zone
    'wizzards-retreat': ZONES_DIR / "internet" / 'components' / 'wizzards-retreat',
    # enterprise zone
    "hex-legacy-1": ZONES_DIR / "enterprise" / 'components' / "hex-legacy-1",
    "bursar-desk": ZONES_DIR / "enterprise" / "components" / 'bursar-desk',
    # operational zone
    "uupl-historian": ZONES_DIR / 'operational' / "components" / 'uupl-historian',
    "distribution-scada": ZONES_DIR / 'operational' / "components" / "distribution-scada",
    "uupl-eng-ws": ZONES_DIR / 'operational' / "components" / "uupl-eng-ws",
    # control zone devices
    'hex-turbine-plc': ZONES_DIR / 'control' / 'components' / "hex-turbine-plc",
    'ied-relay': ZONES_DIR / "control" / "components" / "ied-relay",  # 1:N (relay-a + relay-b), generic
    "uupl-meter": ZONES_DIR / "control" / "components" / "uupl-meter",
    'actuator-modbus-sim': ZONES_DIR / "control" / 'components' / 'actuator-modbus-sim',  # 1:N (4 actuators), generic
    "uupl-mqtt": ZONES_DIR / "control" / "components" / "uupl-mqtt",
    'uupl-modbus-gw': ZONES_DIR / "control" / "components" / "uupl-modbus-gw",
    "uupl-hmi": ZONES_DIR / "control" / "components" / "uupl-hmi",
    'hex-turbine-opcua': ZONES_DIR / 'control' / "components" / 'hex-turbine-opcua',
    # dmz zone (dir == container name)
    'guild-exchange': ZONES_DIR / "dmz" / "components" / "guild-exchange",
    "sorting-office": ZONES_DIR / "dmz" / "components" / 'sorting-office',
    'clacks-relay': ZONES_DIR / 'dmz' / "components" / "clacks-relay",
    'guild-register': ZONES_DIR / "dmz" / "components" / "guild-register",
    'substation-rtu': ZONES_DIR / "dmz" / 'components' / "substation-rtu",
    'contractors-gate': ZONES_DIR / "dmz" / 'components' / "contractors-gate",
    "dispatch-box": ZONES_DIR / "dmz" / "components" / "dispatch-box",
    "guild-clock": ZONES_DIR / "dmz" / 'components' / "guild-clock",
    'city-directory': ZONES_DIR / 'dmz' / 'components' / 'city-directory',
    "scribes-post": ZONES_DIR / 'dmz' / 'components' / "scribes-post"
}


def load_config(config_path: Path) -> dict:
    with open(config_path) as f:
        raw = f.read()
    # two passes: parse for values, resolve {{ }} refs, parse again
    partial = yaml.safe_load(raw)
    rendered = _render_templates(raw, partial)
    return yaml.safe_load(rendered)


def _render_templates(text: str, config: dict) -> str:
    """Resolve {{ dotted.key.path }} references against config."""
    def resolve(match):
        path = match.group(1).strip().split(".")
        val = config
        for key in path:
            if isinstance(val, dict) and key in val:
                val = val[key]
            else:
                raise ValueError(f"unresolved template reference: {{{{ {match.group(1).strip()} }}}}")
        return str(val)
    return re.sub(r"\{\{([^}]+)\}\}", resolve, text)


def _rel(abs_path, base_dir: Path) -> str:
    return os.path.relpath(str(abs_path), str(base_dir))


def _net(config: dict, key: str) -> str:
    return config["networks"][key]["docker_name"]


def _subnet(config: dict, key: str) -> str:
    return config["networks"][key]["subnet"]


def _external_net(name: str) -> dict:
    return {'external': True, "name": name}


# compose builds these images; clab (not compose) starts them
_CLAB_ZONES = ("internet", "enterprise", 'operational', "control", "dmz")


def _service(impl, base_dir, name, hostname, networks, *, cap_add=True, **extra):
    """Build the compose service skeleton shared by every zone; extras layer on top."""
    _check_impl(impl)
    svc = {
        "build": {"context": _rel(COMPONENT_DIRS[impl], base_dir)},
        "container_name": name,
        "hostname": hostname,
        "restart": "unless-stopped",
        "networks": networks,
    }
    if cap_add:
        svc["cap_add"] = ["NET_ADMIN"]
    for key, val in extra.items():
        if val is not None:
            svc[key] = val
    return svc


def generate_enterprise_compose(config: dict, output_path: Path) -> dict:
    ez = config["enterprise_zone"]
    ent_net = _net(config, "enterprise")
    ops_net = _net(config, "operational")
    base_dir = output_path.parent

    lw = ez["legacy_workstation"]
    ew = ez["enterprise_workstation"]
    # bursar-desk dual-homed by accretion: temporary ops access nobody revoked
    services = {
        "hex-legacy-1": _service(
            lw["implementation"], base_dir, "hex-legacy-1", lw["hostname"],
            {ent_net: {"ipv4_address": lw["ip"]}},
        ),
        "bursar-desk": _service(
            ew["implementation"], base_dir, "bursar-desk", ew["hostname"],
            {ent_net: {"ipv4_address": ew["ip"]},
             ops_net: {"ipv4_address": ew["ops_ip"]}},
        ),
    }

    return {
        "services": services,
        "networks": {
            ent_net: _external_net(ent_net),
            ops_net: _external_net(ops_net),
        },
    }


def generate_certs(repo_root: Path) -> Path:
    """Generate CA, server and client certs in <repo_root>/certs/ (gitignored).

    The client key is later chmod 644 by distribution-scada: CTF vuln HEX-5103.
    """
    certs_dir = repo_root / "certs"
    ca_key = certs_dir / "ca.key"
    ca_crt = certs_dir / "ca.crt"
    srv_key = certs_dir / "server.key"
    srv_crt = certs_dir / "server.crt"
    cli_key = certs_dir / 'client.key'
    cli_crt = certs_dir / 'client.crt'

    if all(p.exists() for p in [ca_crt, srv_crt, cli_crt]):
        logging.info("Certs already exist, skipping generation.")
        return certs_dir

    certs_dir.mkdir(exist_ok=True)

    subj_ca = '/CN=UUPL-ModbusCA/O=Unseen University Power and Light Co/C=AM'
    subj_srv = "/CN=uupl-modbus-gw/O=Unseen University Power and Light Co/C=AM"
    subj_cli = "/CN=scadalts-client/O=Unseen University Power and Light Co/C=AM"

    def run(args):
        subprocess.run(args, check=True, capture_output=True)

    logging.info("Generating TLS certs in certs/ ...")

    # CA
    run(["openssl", 'genrsa', "-out", str(ca_key), '2048'])
    run(["openssl", "req", "-new", "-x509", "-days", "3650",
         "-key", str(ca_key), "-out", str(ca_crt), "-subj", subj_ca])

    # server cert (uupl-modbus-gw)
    srv_csr = certs_dir / "server.csr"
    run(["openssl", "genrsa", "-out", str(srv_key), "2048"])
    run(["openssl", "req", "-new", "-key", str(srv_key),
         "-out", str(srv_csr), "-subj", subj_srv])
    run(["openssl", "x509", '-req', "-days", "730",
         '-in', str(srv_csr), '-CA', str(ca_crt), "-CAkey", str(ca_key),
         "-CAcreateserial", "-out", str(srv_crt)])
    srv_csr.unlink()

    # client cert (distribution-scada)
    cli_csr = certs_dir / "client.csr"
    run(["openssl", "genrsa", "-out", str(cli_key), "2048"])
    run(["openssl", "req", "-new", "-key", str(cli_key),
         "-out", str(cli_csr), "-subj", subj_cli])
    run(["openssl", "x509", '-req', '-days', '3650',
         '-in', str(cli_csr), "-CA", str(ca_crt), "-CAkey", str(ca_key),
         "-CAcreateserial", "-out", str(cli_crt)])
    cli_csr.unlink()

    # client entrypoint later widens client.key to 644 (CTF vuln HEX-5103)
    srv_key.chmod(0o600)
    cli_key.chmod(0o600)

    logging.info(f"Certs written to {certs_dir}")
    return certs_dir


def generate_operational_compose(config: dict, output_path: Path) -> dict:
    oz = config["operational_zone"]
    ops_net = _net(config, "operational")
    ctrl_net = _net(config, "control")
    base_dir = output_path.parent
    certs_dir = REPO_ROOT / "certs"

    hist = oz["historian"]
    services = {
        "uupl-historian": _service(
            hist["implementation"], base_dir, "uupl-historian", hist["hostname"],
            {ops_net: {"ipv4_address": hist["ip"]}},
            environment={"DATA_SOURCE": hist.get("data_source", config["ics_process"])},
        ),
    }

    # world-readable client.key is HEX-5103 (risk accepted 2020)
    scada = oz["scada_server"]
    gw_ops_ip = oz.get("stunnel_gateway", {}).get("ops_ip", "10.10.2.50")
    services["distribution-scada"] = _service(
        scada["implementation"], base_dir, "distribution-scada", scada["hostname"],
        {ops_net: {"ipv4_address": scada["ip"]}},
        environment={
            "HISTORIAN_IP": scada.get("historian_ip", hist["ip"]),
            "STUNNEL_GW_IP": gw_ops_ip,
        },
        volumes=[
            f"{_rel(certs_dir / 'client.crt', base_dir)}:/run/stunnel-certs/client.crt",
            f"{_rel(certs_dir / 'client.key', base_dir)}:/run/stunnel-certs/client.key",
            f"{_rel(certs_dir / 'ca.crt', base_dir)}:/run/stunnel-certs/ca.crt",
        ],
    )

    # stunnel gateway: TLS from SCADA on ops, plain Modbus to the PLC on control
    gw_cfg = oz.get("stunnel_gateway")
    if gw_cfg:
        gw_component = COMPONENT_DIRS[gw_cfg["implementation"]]
        services["uupl-modbus-gw"] = _service(
            gw_cfg["implementation"], base_dir, "uupl-modbus-gw", gw_cfg["hostname"],
            {ops_net: {"ipv4_address": gw_cfg["ops_ip"]},
             ctrl_net: {"ipv4_address": gw_cfg["ctrl_ip"]}},
            environment={"FORWARD_TARGET": gw_cfg.get("forward_to", "10.10.3.21:502")},
            volumes=[
                f"{_rel(gw_component / 'stunnel.conf', base_dir)}:/run/stunnel/stunnel.conf:ro",
                f"{_rel(certs_dir / 'ca.crt', base_dir)}:/run/stunnel/ca.crt:ro",
                f"{_rel(certs_dir / 'server.crt', base_dir)}:/run/stunnel/server.crt:ro",
                f"{_rel(certs_dir / 'server.key', base_dir)}:/run/stunnel/server.key:ro",
            ],
        )

    # the pivot into the control zone (dual-homed ops + control)
    eng = oz["engineering_workstation"]
    services["uupl-eng-ws"] = _service(
        eng["implementation"], base_dir, "uupl-eng-ws", eng["hostname"],
        {ops_net: {"ipv4_address": eng["ip"]},
         ctrl_net: {"ipv4_address": eng["ctrl_ip"]}},
        environment={
            "ICS_PROCESS": eng.get("ics_process", config["ics_process"]),
            "CONTROL_SUBNET": eng.get("control_network_subnet", _subnet(config, "control")),
        },
    )

    return {
        "services": services,
        "networks": {
            ops_net: _external_net(ops_net),
            ctrl_net: _external_net(ctrl_net),
        },
    }


def generate_control_compose(config: dict, output_path: Path) -> dict:
    ctrl_net = _net(config, "control")
    base_dir = output_path.parent
    services = {}

    for dev in config.get("control_zone", {}).get("devices", []):
        svc_name = dev["name"].replace("_", "-")
        services[svc_name] = _service(
            dev["implementation"], base_dir, dev["name"], dev.get("hostname", dev["name"]),
            {ctrl_net: {"ipv4_address": dev["ip"]}},
            environment=dev.get("env") or None,
        )

        # sidecar shares the parent netns when it has no ip, else takes its own
        for sidecar in dev.get("sidecars", []):
            _check_impl(sidecar["implementation"])
            sc_name = sidecar["name"].replace("_", "-")
            sc_svc = {
                "build": {"context": _rel(COMPONENT_DIRS[sidecar["implementation"]], base_dir)},
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

    return {
        "services": services,
        "networks": {ctrl_net: _external_net(ctrl_net)},
    }


def generate_dmz_compose(config: dict, output_path: Path) -> dict:
    """Generate zones/dmz/docker-compose.yml; an enterprise_ip dual-homes a device (contractor pivot)."""
    dmz_net = _net(config, "dmz")
    ent_net = _net(config, "enterprise")
    base_dir = output_path.parent
    services = {}
    networks_used = {dmz_net}

    for dev in config.get("dmz_zone", {}).get("devices", []):
        svc_name = dev["name"].replace("_", "-")
        networks = {dmz_net: {"ipv4_address": dev["ip"]}}
        if "enterprise_ip" in dev:
            networks[ent_net] = {"ipv4_address": dev["enterprise_ip"]}
            networks_used.add(ent_net)

        svc = _service(
            dev["implementation"], base_dir, dev["name"], dev.get("hostname", dev["name"]),
            networks,
            environment=dev.get("env") or None,
        )
        if dev.get("syslog_logging"):
            svc["logging"] = {
                "driver": "syslog",
                "options": {
                    "syslog-address": "udp://10.10.5.32:514",
                    "tag": dev.get("hostname", dev["name"]),
                },
            }
            svc.setdefault("depends_on", []).append("scribes-post")

        services[svc_name] = svc

    return {
        "services": services,
        "networks": {n: _external_net(n) for n in networks_used},
    }


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


def generate_internet_zone_compose(config: dict, output_path: Path) -> dict:
    """Generate zones/internet/docker-compose.yml: attacker machine plus any internet_zone nodes."""
    inet_net = _net(config, "internet")
    ent_net = _net(config, "enterprise")
    ops_net = _net(config, "operational")
    base_dir = output_path.parent
    services = {}
    networks_used = {inet_net}

    # attacker machine: fixed build dir (no implementation key), privileged not cap_add,
    # so it is built by hand rather than through _service
    jh = config["attacker_machine"]
    ssh_host_port = jh.get("ssh_host_port", 22)
    auth_mode = jh.get("auth_mode", "key")
    attacker_dir = ZONES_DIR / "internet" / "components" / "unseen-gate"
    attacker_rel = _rel(attacker_dir, base_dir)

    svc = {
        "build": {"context": attacker_rel},
        "container_name": "unseen-gate",
        "hostname": jh["hostname"],
        "restart": "unless-stopped",
        "networks": {inet_net: {"ipv4_address": jh["internet_ip"]}},
        "ports": [f"{ssh_host_port}:22"],
        # mounted in both auth modes
        "volumes": [f"./{attacker_rel}/adversary-readme.txt:/run/adversary-readme.txt:ro"],
    }
    if auth_mode == "password":
        # password mode: credentials from config (Root-Me and similar platforms)
        accounts = jh.get("accounts", {})
        account_str = " ".join(f"{u}:{p}" for u, p in accounts.items())
        svc["environment"] = {"AUTH_MODE": "password", "AUTH_ACCOUNTS": account_str}
    else:
        # key mode (default): pubkey auth, keys mounted at runtime
        svc["volumes"].insert(0, f"./{attacker_rel}/adversary-keys:/run/adversary-keys:ro")
    svc["privileged"] = True  # required to issue mount(2) from inside the container
    services["unseen-gate"] = svc

    # optional admin_home node (wizzards-retreat): privileged for a tmpfs mount, no cap_add
    ah = config.get("internet_zone", {}).get("admin_home")
    if ah:
        ah_networks = {
            inet_net: {"ipv4_address": ah["internet_ip"]},
            ent_net: {"ipv4_address": ah["enterprise_ip"]},
        }
        networks_used.add(ent_net)
        if "operational_ip" in ah:
            ah_networks[ops_net] = {"ipv4_address": ah["operational_ip"]}
            networks_used.add(ops_net)
        services["wizzards-retreat"] = _service(
            ah["implementation"], base_dir, "wizzards-retreat", ah["hostname"],
            ah_networks, cap_add=False, privileged=True,
        )
        # unseen-gate (NFS client) stops before wizzards-retreat (NFS server):
        # compose down reverses depends_on order.
        services["unseen-gate"]["depends_on"] = ["wizzards-retreat"]

    return {
        "services": services,
        "networks": {n: _external_net(n) for n in networks_used},
    }


def generate_adversary_readme() -> str:
    # static briefing; deliberately withholds enterprise addressing from a freshly-landed attacker
    return ADVERSARY_README.read_text()


def _router_ip(subnet: str, host: int) -> str:
    prefix = subnet.split('/')[0].rsplit('.', 1)[0]
    return f"{prefix}.{host}"


def generate_routers(config: dict) -> None:
    """Write per-router iptables ACL scripts to infrastructure/routers/generated/."""
    nets = config["networks"]
    out = ROUTERS_DIR / "generated"
    out.mkdir(parents=True, exist_ok=True)

    def subnet(key):  return nets[key]["subnet"]
    def netname(key): return nets[key]["docker_name"]
    def rip(key, h):  return _router_ip(subnet(key), h)

    historian = config["operational_zone"]['historian']["ip"]
    scada = config["operational_zone"]['scada_server']['ip']
    eng_ws = config['operational_zone']["engineering_workstation"]['ip']
    bastion_ip = next(
        (d["ip"] for d in config.get("dmz_zone", {}).get("devices", [])
         if d.get("implementation") == 'contractors-gate'),
        "0.0.0.0/32"
    )


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
        f"iptables -A FORWARD -s {bastion_ip} -d {subnet('enterprise')} -j ACCEPT\n"
        f"# All else: DROP (default policy)\n"
    )

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

    # clab binds these as /acl.sh
    for acl in out.glob("*-acl.sh"):
        acl.chmod(0o755)

    # drop a stale docker-compose.yml from the retired compose-managed router stack
    compose_path = out / "docker-compose.yml"
    if compose_path.exists():
        compose_path.unlink()
    logging.info(f"Router ACL scripts written to {out}")


# host-owned Linux bridges (created on up, deleted on down); clab never owns them

_CLAB_BRIDGES = ("ics_internet", 'ics_enterprise', "ics_operational",
                 'ics_control', "ics_dmz", 'ics_wan')


def generate_clab_helpers(config: dict) -> None:
    """Write infrastructure/clab-up.sh and clab-down.sh."""
    bridges = ' '.join(_CLAB_BRIDGES)

    deploy = "\n".join(
        f'containerlab deploy --topo "$REPO/clab/{z}-zone.clab.yaml"'
        for z in _CLAB_ZONES
    )
    # --cleanup wipes the clab state dir so the next deploy is not blocked by a
    # stale "lab already deployed" registration.
    destroy_topos = "\n".join(
        f'containerlab destroy --cleanup --topo "$REPO/clab/{z}-zone.clab.yaml"'
        for z in reversed(_CLAB_ZONES)
    )
    # drop containers still labelled from a node removed between deploys, else
    # the next deploy aborts with "lab already deployed".
    destroy_labels = "\n".join(
        (
            f'leftover=$(docker ps -aq --filter "label=containerlab=uupl-{z}" 2>/dev/null) && '
            f'[ -n "$leftover" ] && docker rm -f $leftover >/dev/null 2>&1 || true'
        )
        for z in _CLAB_ZONES
    )
    destroy = destroy_topos + "\n\n" + (
        'echo "[clab] Removing any containers still labeled containerlab=uupl-*..."\n'
        + destroy_labels
    )

    # Host gets 10.10.0.1/24 on ics_internet so it can route to the container
    # subnet; ./ctl ssh reaches 10.10.0.5:22 directly. INPUT DROP stops
    # containers reaching host services via the bridge IP.
    bridge_setup = (
        "ip addr show dev ics_internet | grep -q '10\\.10\\.0\\.1/24' "
        '|| ip addr add 10.10.0.1/24 dev ics_internet; '
        'iptables -C INPUT -i ics_internet -j DROP 2>/dev/null '
        '|| iptables -A INPUT -i ics_internet -j DROP'
    )
    bridge_teardown = (
        "iptables -D INPUT -i ics_internet -j DROP 2>/dev/null; "
        'ip addr flush dev ics_internet 2>/dev/null'
    )

    up = INFRA_DIR / "clab-up.sh"
    up.write_text(
        "#!/usr/bin/env bash\n"
        "# Generated by orchestrator/generate.py, do not edit directly.\n"
        "set -euo pipefail\n"
        'REPO="$(cd "$(dirname "$0")/.." && pwd)"\n\n'
        'echo "[clab] Creating host bridges (sudo)..."\n'
        f"sudo bash -c '"
        f'for b in {bridges}; do '
        'ip link show "$b" >/dev/null 2>&1 || ip link add "$b" type bridge; '
        'ip link set "$b" up; '
        # BPDU guard intentionally absent: STP root takeover is the attack surface
        'ip link set "$b" type bridge stp_state 1; '
        # mcast snooping off so OSPF Hello multicast floods (unmanaged OT switch)
        'ip link set "$b" type bridge mcast_snooping 0; '
        'done; '
        f"{bridge_setup}'\n\n"
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
        'echo "[clab] Removing host bridges (sudo)..."\n'
        f"sudo bash -c '"
        f"{bridge_teardown}; "
        f'for b in {bridges}; do '
        'ip link delete "$b" type bridge 2>/dev/null; done\'\n'
    )
    down.chmod(0o755)
    logging.info(f"Wrote: {up}")
    logging.info(f"Wrote: {down}")


def main() -> None:
    config_path = (
        Path(sys.argv[1]) if len(sys.argv) > 1
        else ORCHESTRATOR_DIR / 'ctf-config.yaml'
    )

    logging.info(f"Loading config: {config_path}")
    config = load_config(config_path)

    # certs only needed when the stunnel gateway is present
    oz = config.get('operational_zone', {})
    needs_certs = bool(oz.get('stunnel_gateway'))
    if needs_certs:
        generate_certs(REPO_ROOT)

    # data plane is real Linux bridges now; drop a legacy networks compose if present
    legacy_networks = INFRA_DIR / "networks" / 'docker-compose.yml'
    if legacy_networks.exists():
        legacy_networks.unlink()

    enterprise_path = ZONES_DIR / "enterprise"  / "docker-compose.yml"
    operational_path = ZONES_DIR / "operational" / "docker-compose.yml"
    control_path = ZONES_DIR / "control"     / "docker-compose.yml"

    write_compose(enterprise_path,  generate_enterprise_compose(config, enterprise_path))
    write_compose(operational_path, generate_operational_compose(config, operational_path))
    write_compose(control_path,     generate_control_compose(config, control_path))

    internet_path = ZONES_DIR / 'internet' / "docker-compose.yml"
    write_compose(internet_path, generate_internet_zone_compose(config, internet_path))
    write_text(ZONES_DIR / "internet" / "components" / "unseen-gate" / 'adversary-readme.txt', generate_adversary_readme())

    if config.get("dmz_zone"):
        dmz_path = ZONES_DIR / 'dmz' / "docker-compose.yml"
        write_compose(dmz_path, generate_dmz_compose(config, dmz_path))

    generate_routers(config)
    generate_clab_helpers(config)

    # drop stale artefacts from earlier generator iterations
    for stale in (
        INFRA_DIR / 'firewall.sh',
        INFRA_DIR / ".fabric",
        REPO_ROOT / "start.sh",
        REPO_ROOT / 'stop.sh',
    ):
        if stale.exists():
            stale.unlink()

    logging.info("Done. Run: ./ctl up")


if __name__ == "__main__":
    main()
