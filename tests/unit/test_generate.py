"""Unit tests for orchestrator/generate.py.

No Docker. No subprocess calls. Tests each generator function in isolation
using the real ctf-config.yaml.
"""
import json
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "orchestrator"))

import generate as gen  # noqa: E402

CONFIG_PATH = REPO_ROOT / "orchestrator" / "ctf-config.yaml"


@pytest.fixture(scope="module")
def config():
    return gen.load_config(CONFIG_PATH)


@pytest.fixture(scope="module")
def enterprise_output_path():
    return REPO_ROOT / "zones" / "enterprise" / "docker-compose.yml"


@pytest.fixture(scope="module")
def operational_output_path():
    return REPO_ROOT / "zones" / "operational" / "docker-compose.yml"


@pytest.fixture(scope="module")
def attacker_machine_output_path():
    return REPO_ROOT / "zones" / "internet" / "docker-compose.yml"


@pytest.fixture(scope="module")
def dmz_output_path():
    return REPO_ROOT / "zones" / "dmz" / "docker-compose.yml"


# ---------------------------------------------------------------------------
# Template rendering
# ---------------------------------------------------------------------------

def test_render_templates(config):
    """Known placeholders resolve; unknown placeholders are left intact."""
    text = "subnet={{ networks.control.subnet }} unknown={{ no.such.key }}"
    result = gen._render_templates(text, config)

    expected_subnet = config["networks"]["control"]["subnet"]
    assert expected_subnet in result, "control subnet should be resolved"
    assert "{{ no.such.key }}" in result, "unresolved placeholders should be preserved"
    assert "{{ networks.control.subnet }}" not in result, "resolved placeholder should not remain"


# ---------------------------------------------------------------------------
# Networks compose
# ---------------------------------------------------------------------------

def test_generate_networks_compose(config):
    """Four networks with correct docker_name keys and IPAM subnets."""
    compose = gen.generate_networks_compose(config)

    networks = compose["networks"]
    assert len(networks) == 6, "expected 6 networks"

    for key, net_cfg in config["networks"].items():
        docker_name = net_cfg["docker_name"]
        subnet = net_cfg["subnet"]
        assert docker_name in networks, f"network {docker_name!r} missing"
        ipam_subnets = [
            c["subnet"]
            for c in networks[docker_name].get("ipam", {}).get("config", [])
        ]
        assert subnet in ipam_subnets, f"subnet {subnet} not in IPAM for {docker_name}"


# ---------------------------------------------------------------------------
# Enterprise compose
# ---------------------------------------------------------------------------

def test_generate_enterprise_compose(config, enterprise_output_path):
    """Legacy workstation on enterprise only; enterprise-workstation dual-homed."""
    compose = gen.generate_enterprise_compose(config, enterprise_output_path)
    services = compose["services"]

    ent_net = gen._net(config, "enterprise")
    ops_net = gen._net(config, "operational")
    lw_ip = config["enterprise_zone"]["legacy_workstation"]["ip"]
    ew_ip = config["enterprise_zone"]["enterprise_workstation"]["ip"]
    ew_ops_ip = config["enterprise_zone"]["enterprise_workstation"]["ops_ip"]

    # Legacy workstation — enterprise only
    assert "legacy-workstation" in services
    lw = services["legacy-workstation"]
    assert ent_net in lw["networks"], "legacy-workstation should be on enterprise network"
    assert ops_net not in lw["networks"], "legacy-workstation should not be on ops network"
    assert lw["networks"][ent_net]["ipv4_address"] == lw_ip

    # Enterprise workstation — dual-homed
    assert "enterprise-workstation" in services
    ew = services["enterprise-workstation"]
    assert ent_net in ew["networks"], "enterprise-workstation missing enterprise network"
    assert ops_net in ew["networks"], "enterprise-workstation missing operational network"
    assert ew["networks"][ent_net]["ipv4_address"] == ew_ip
    assert ew["networks"][ops_net]["ipv4_address"] == ew_ops_ip


# ---------------------------------------------------------------------------
# Operational compose
# ---------------------------------------------------------------------------

def test_generate_operational_compose(config, operational_output_path):
    """Historian/SCADA on ops only; engineering-workstation dual-homed to control."""
    compose = gen.generate_operational_compose(config, operational_output_path)
    services = compose["services"]

    ops_net = gen._net(config, "operational")
    ctrl_net = gen._net(config, "control")
    hist_ip = config["operational_zone"]["historian"]["ip"]
    scada_ip = config["operational_zone"]["scada_server"]["ip"]
    eng_ip = config["operational_zone"]["engineering_workstation"]["ip"]
    eng_ctrl_ip = config["operational_zone"]["engineering_workstation"]["ctrl_ip"]

    # Historian — ops only
    assert "historian" in services
    hist = services["historian"]
    assert ops_net in hist["networks"]
    assert ctrl_net not in hist["networks"]
    assert hist["networks"][ops_net]["ipv4_address"] == hist_ip

    # SCADA — ops only
    assert "scada-server" in services
    scada = services["scada-server"]
    assert ops_net in scada["networks"]
    assert ctrl_net not in scada["networks"]
    assert scada["networks"][ops_net]["ipv4_address"] == scada_ip

    # Eng workstation — dual-homed
    assert "engineering-workstation" in services
    eng = services["engineering-workstation"]
    assert ops_net in eng["networks"]
    assert ctrl_net in eng["networks"]
    assert eng["networks"][ops_net]["ipv4_address"] == eng_ip
    assert eng["networks"][ctrl_net]["ipv4_address"] == eng_ctrl_ip


# ---------------------------------------------------------------------------
# Firewall script
# ---------------------------------------------------------------------------

def test_generate_firewall_sh(config):
    """All zone subnets present; root-check and iptables flush present."""
    script = gen.generate_firewall_sh(config)

    for key in ("internet", "enterprise", "operational", "control", "wan", "dmz"):
        subnet = config["networks"][key]["subnet"]
        assert subnet in script, f"subnet {subnet} ({key}) missing from firewall.sh"

    assert 'if [ "$EUID" -ne 0 ]' in script, "root check block missing"
    assert "iptables -F DOCKER-USER" in script, "iptables flush missing"
    assert "-A DOCKER-USER -j RETURN" in script, "final RETURN rule missing"


# ---------------------------------------------------------------------------
# Adversary README
# ---------------------------------------------------------------------------

def test_generate_adversary_readme(config):
    """README renders without unresolved placeholders.

    The README no longer lists internal IPs (attacker machine has no enterprise NIC).
    Just verify there are no bare braces left.
    """
    readme = gen.generate_adversary_readme(config)
    assert "{" not in readme, f"unresolved placeholder(s) remain in readme:\n{readme}"
    assert len(readme.strip()) > 0, "adversary readme is empty"


# ---------------------------------------------------------------------------
# DMZ compose
# ---------------------------------------------------------------------------

def test_generate_dmz_compose(config, dmz_output_path):
    """10 DMZ services; ssh-bastion dual-homed on dmz+enterprise; others dmz-only."""
    compose = gen.generate_dmz_compose(config, dmz_output_path)
    services = compose["services"]

    dmz_net = gen._net(config, "dmz")
    ent_net = gen._net(config, "enterprise")

    assert len(services) == 10, f"expected 10 DMZ services, got {len(services)}"

    # ssh-bastion is dual-homed
    assert "ssh-bastion" in services
    bastion = services["ssh-bastion"]
    assert dmz_net in bastion["networks"], "ssh-bastion missing dmz network"
    assert ent_net in bastion["networks"], "ssh-bastion missing enterprise network"
    assert bastion["networks"][dmz_net]["ipv4_address"] == "10.10.5.20"
    assert bastion["networks"][ent_net]["ipv4_address"] == "10.10.1.30"

    # All other services are dmz-only
    for svc_name, svc in services.items():
        if svc_name == "ssh-bastion":
            continue
        assert dmz_net in svc["networks"], f"{svc_name} missing dmz network"
        assert ent_net not in svc["networks"], f"{svc_name} should not be on enterprise network"

    # Spot-check a few IPs
    assert "umati-gateway" in services
    assert services["umati-gateway"]["networks"][dmz_net]["ipv4_address"] == "10.10.5.10"
    assert services["syslog-relay"]["networks"][dmz_net]["ipv4_address"] == "10.10.5.32"


# ---------------------------------------------------------------------------
# Attacker machine compose
# ---------------------------------------------------------------------------

def test_generate_attacker_machine_compose(config, attacker_machine_output_path):
    """Attacker machine is in the internet zone compose, internet-only, correct IP and ports."""
    compose = gen.generate_internet_zone_compose(config, attacker_machine_output_path)
    services = compose["services"]

    assert "attacker-machine" in services, "attacker-machine missing from internet zone compose"
    jh = services["attacker-machine"]

    inet_net = gen._net(config, "internet")
    ent_net  = gen._net(config, "enterprise")
    jh_internet_ip = config["attacker_machine"]["internet_ip"]

    assert inet_net in jh["networks"], "attacker-machine missing internet network"
    assert jh["networks"][inet_net]["ipv4_address"] == jh_internet_ip
    assert ent_net not in jh["networks"], "attacker-machine must NOT be on enterprise network"

    ssh_host_port = config["attacker_machine"].get("ssh_host_port", 22)
    assert f"{ssh_host_port}:22" in jh["ports"], "attacker-machine SSH port mapping missing"

    volumes_str = " ".join(jh.get("volumes", []))
    assert "adversary-keys" in volumes_str, "adversary-keys volume missing"
    assert "adversary-readme.txt" in volumes_str, "adversary-readme.txt volume missing"


