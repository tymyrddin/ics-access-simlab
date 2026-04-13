"""Integration tests for generate.py output artifacts.

Invokes generate.py as a subprocess, then checks all output files exist,
parse as valid YAML (where applicable), and contain expected content.
No Docker required.
"""
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = REPO_ROOT / "orchestrator" / "ctf-config.yaml"

GENERATED_FILES = [
    REPO_ROOT / "infrastructure" / "networks" / "docker-compose.yml",
    REPO_ROOT / "zones" / "enterprise" / "docker-compose.yml",
    REPO_ROOT / "zones" / "operational" / "docker-compose.yml",
    REPO_ROOT / "zones" / "control" / "docker-compose.yml",
    REPO_ROOT / "zones" / "dmz" / "docker-compose.yml",
    REPO_ROOT / "start.sh",
    REPO_ROOT / "stop.sh",
    REPO_ROOT / "infrastructure" / "firewall.sh",
    REPO_ROOT / "zones" / "internet" / "docker-compose.yml",
    REPO_ROOT / "zones" / "internet" / "components" / "attacker-machine" / "adversary-readme.txt",
]

COMPOSE_FILES = [p for p in GENERATED_FILES if p.suffix in (".yml", ".yaml")]


def setup_module(module):
    """Run generate.py before any test in this module."""
    result = subprocess.run(
        [sys.executable, "orchestrator/generate.py"],
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        pytest.fail(
            f"generate.py exited with code {result.returncode}.\n"
            f"stdout:\n{result.stdout}\n"
            f"stderr:\n{result.stderr}"
        )


# ---------------------------------------------------------------------------
# File existence
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("path", GENERATED_FILES, ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_all_output_files_exist(path):
    assert path.exists(), f"generated file missing: {path.relative_to(REPO_ROOT)}"


# ---------------------------------------------------------------------------
# YAML validity
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("path", COMPOSE_FILES, ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_compose_files_are_valid_yaml(path):
    try:
        with open(path) as f:
            data = yaml.safe_load(f)
        assert isinstance(data, dict), f"{path.name} parsed as {type(data).__name__}, expected dict"
    except yaml.YAMLError as exc:
        pytest.fail(f"{path.relative_to(REPO_ROOT)} is not valid YAML: {exc}")


# ---------------------------------------------------------------------------
# IP address presence
# ---------------------------------------------------------------------------

def test_enterprise_ips_in_output():
    """Legacy workstation and enterprise workstation IPs in enterprise compose."""
    content = (REPO_ROOT / "zones" / "enterprise" / "docker-compose.yml").read_text()
    assert "10.10.1.10" in content, "legacy workstation IP 10.10.1.10 missing"
    assert "10.10.1.20" in content, "enterprise workstation IP 10.10.1.20 missing"


def test_operational_ips_in_output():
    """Historian, SCADA, and engineering-workstation IPs in operational compose."""
    content = (REPO_ROOT / "zones" / "operational" / "docker-compose.yml").read_text()
    assert "10.10.2.10" in content, "historian IP 10.10.2.10 missing"
    assert "10.10.2.20" in content, "SCADA IP 10.10.2.20 missing"
    assert "10.10.2.30" in content, "engineering-workstation IP 10.10.2.30 missing"


def test_jump_host_ip_in_output():
    """Attacker machine and admin-home IPs both in internet zone compose."""
    content = (REPO_ROOT / "zones" / "internet" / "docker-compose.yml").read_text()
    assert "10.10.0.5" in content, "attacker machine internet IP 10.10.0.5 missing"
    assert "10.10.0.10" in content, "admin-home internet IP 10.10.0.10 missing"
    assert "10.10.1.5" not in content, "attacker machine must not have enterprise IP"


# ---------------------------------------------------------------------------
# Adversary README
# ---------------------------------------------------------------------------

def test_adversary_readme_no_placeholders():
    """Generated adversary-readme.txt must have no unresolved {placeholders}."""
    content = (REPO_ROOT / "zones" / "internet" / "components" / "attacker-machine" / "adversary-readme.txt").read_text()
    assert "{enterprise_subnet}" not in content, "{enterprise_subnet} not resolved"
    assert "{legacy_ws_ip}" not in content, "{legacy_ws_ip} not resolved"
    assert "{ent_ws_ip}" not in content, "{ent_ws_ip} not resolved"
    # Paranoia check: no bare brace pairs remain
    import re
    leftover = re.findall(r"\{[a-z_]+\}", content)
    assert not leftover, f"unresolved placeholder(s) in adversary-readme.txt: {leftover}"


# ---------------------------------------------------------------------------
# Firewall script
# ---------------------------------------------------------------------------

def test_firewall_sh_contains_zone_subnets():
    """firewall.sh must contain all zone subnets including DMZ."""
    content = (REPO_ROOT / "infrastructure" / "firewall.sh").read_text()
    for subnet in ("10.10.1.0/24", "10.10.2.0/24", "10.10.3.0/24", "10.10.4.0/24", "10.10.5.0/24"):
        assert subnet in content, f"subnet {subnet} missing from firewall.sh"


def test_dmz_ips_in_output():
    """Key DMZ device IPs are present in the dmz compose."""
    content = (REPO_ROOT / "zones" / "dmz" / "docker-compose.yml").read_text()
    assert "10.10.5.10" in content, "umati-gateway IP 10.10.5.10 missing"
    assert "10.10.5.20" in content, "ssh-bastion IP 10.10.5.20 missing"
    assert "10.10.5.30" in content, "ntp-server IP 10.10.5.30 missing"
    assert "10.10.1.30" in content, "ssh-bastion enterprise IP 10.10.1.30 missing"
