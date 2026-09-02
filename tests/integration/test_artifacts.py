"""Integration tests: run generate.py, check output files exist and parse."""
import subprocess
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
CONFIG_PATH = REPO_ROOT / 'orchestrator' / "ctf-config.yaml"

GENERATED_FILES = [
    REPO_ROOT / "zones" / 'enterprise' / 'docker-compose.yml',
    REPO_ROOT / 'zones' / "operational" / "docker-compose.yml",
    REPO_ROOT / 'zones' / "control" / "docker-compose.yml",
    REPO_ROOT / "zones" / "dmz" / "docker-compose.yml",
    REPO_ROOT / 'zones' / "internet" / "docker-compose.yml",
    REPO_ROOT / "zones" / 'internet' / "components" / "unseen-gate" / "adversary-readme.txt",
    REPO_ROOT / "infrastructure" / "clab-up.sh",
    REPO_ROOT / 'infrastructure' / "clab-down.sh",
]

COMPOSE_FILES = [p for p in GENERATED_FILES if p.suffix in ('.yml', ".yaml")]


def setup_module(module):
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


@pytest.mark.parametrize("path", GENERATED_FILES, ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_all_output_files_exist(path):
    assert path.exists(), f"generated file missing: {path.relative_to(REPO_ROOT)}"


@pytest.mark.parametrize('path', COMPOSE_FILES, ids=lambda p: str(p.relative_to(REPO_ROOT)))
def test_compose_files_are_valid_yaml(path):
    try:
        with open(path) as f:
            data = yaml.safe_load(f)
        assert isinstance(data, dict), f"{path.name} parsed as {type(data).__name__}, expected dict"
    except yaml.YAMLError as exc:
        pytest.fail(f"{path.relative_to(REPO_ROOT)} is not valid YAML: {exc}")


def test_enterprise_ips_in_output():
    content = (REPO_ROOT / 'zones' / "enterprise" / "docker-compose.yml").read_text()
    assert '10.10.1.10' in content, 'legacy workstation IP 10.10.1.10 missing'
    assert '10.10.1.20' in content, "enterprise workstation IP 10.10.1.20 missing"


def test_operational_ips_in_output():
    content = (REPO_ROOT / 'zones' / "operational" / "docker-compose.yml").read_text()
    assert "10.10.2.10" in content, 'historian IP 10.10.2.10 missing'
    assert "10.10.2.20" in content, "SCADA IP 10.10.2.20 missing"
    assert "10.10.2.30" in content, 'uupl-eng-ws IP 10.10.2.30 missing'


def test_attacker_machine_ip_in_output():
    content = (REPO_ROOT / 'zones' / "internet" / 'docker-compose.yml').read_text()
    assert "10.10.0.5" in content, 'attacker machine internet IP 10.10.0.5 missing'
    assert "10.10.0.10" in content, "wizzards-retreat internet IP 10.10.0.10 missing"
    assert "10.10.1.5" not in content, "attacker machine must not have enterprise IP"


def test_adversary_readme_no_placeholders():
    content = (REPO_ROOT / 'zones' / "internet" / "components" / "unseen-gate" / "adversary-readme.txt").read_text()
    assert "{enterprise_subnet}" not in content, "{enterprise_subnet} not resolved"
    assert "{legacy_ws_ip}" not in content, "{legacy_ws_ip} not resolved"
    assert '{ent_ws_ip}' not in content, "{ent_ws_ip} not resolved"
    import re
    leftover = re.findall(r"\{[a-z_]+\}", content)
    assert not leftover, f"unresolved placeholder(s) in adversary-readme.txt: {leftover}"


def test_router_acls_reference_all_zone_subnets():
    """Every zone subnet appears in at least one router ACL script."""
    acl_dir = REPO_ROOT / 'infrastructure' / 'routers' / 'generated'
    assert acl_dir.is_dir(), f"router ACL directory missing: {acl_dir}"
    acl_scripts = sorted(acl_dir.glob('*-acl.sh'))
    assert acl_scripts, f"no router ACL scripts under {acl_dir}"
    combined = "\n".join(p.read_text() for p in acl_scripts)
    for subnet in ("10.10.1.0/24", "10.10.2.0/24", '10.10.3.0/24',
                   '10.10.4.0/24', "10.10.5.0/24"):
        assert subnet in combined, (
            f"subnet {subnet} missing from any router ACL script "
            f"(scanned {[p.name for p in acl_scripts]})"
        )


def test_clab_up_sh_creates_zone_bridges():
    content = (REPO_ROOT / "infrastructure" / "clab-up.sh").read_text()
    for bridge in ("ics_internet", "ics_enterprise", "ics_operational",
                   "ics_control", "ics_dmz", "ics_wan"):
        assert bridge in content, f"bridge {bridge} missing from clab-up.sh"


def test_dmz_ips_in_output():
    content = (REPO_ROOT / "zones" / "dmz" / "docker-compose.yml").read_text()
    assert '10.10.5.10' in content, "umati-gateway IP 10.10.5.10 missing"
    assert "10.10.5.20" in content, 'ssh-bastion IP 10.10.5.20 missing'
    assert "10.10.5.30" in content, "ntp-server IP 10.10.5.30 missing"
    assert "10.10.1.30" in content, 'ssh-bastion enterprise IP 10.10.1.30 missing'


ENG_WS_ENTRYPOINT = (
    REPO_ROOT / 'zones' / "operational" / 'components' / "uupl-eng-ws" / "entrypoint.sh"
)


def test_eng_ws_relay_config_artefacts():
    content = ENG_WS_ENTRYPOINT.read_text()
    assert "trip_history_2024.txt" in content, 'trip_history_2024.txt heredoc missing'
    assert 'Annual Report' in content, "trip history labelled Annual Report, not YTD"
    assert "threshold_override_2023-09.txt" in content, 'threshold_override heredoc missing'
    assert "sorting-office" in content, "threshold_override references sorting-office gateway"
    assert 'relay_maintenance_log.txt' in content, "relay_maintenance_log heredoc missing"
    assert "2025" in content, 'relay_maintenance_log has 2025 inspection entry'


def test_eng_ws_document_artefacts():
    content = ENG_WS_ENTRYPOINT.read_text()
    assert 'mqtt_topics.txt' in content, "mqtt_topics.txt heredoc missing"
    assert "freq_x10" in content, "mqtt_topics.txt explains freq_x10 scaling"
    assert "telemetry_sample_2026-01-20.log" in content, 'telemetry_sample heredoc missing'
    assert "snmp_plc_2024-03-15.txt" in content, "snmp_walk heredoc missing"
    assert "rwcommunity" in content, "snmp_walk notes rwcommunity is active"
    assert "grafana_turbine_panel.json" in content, "grafana_turbine_panel heredoc missing"
    assert "alarm_history_2024-Q1.csv" in content, 'alarm_history heredoc missing'


def test_eng_ws_backup_2022_archive():
    content = ENG_WS_ENTRYPOINT.read_text()
    assert 'backup_2022_final_v3.zip' in content, "2022 backup zip missing from entrypoint"
    assert 'plc-access-2022.conf' in content, "2022 backup inner file plc-access-2022.conf missing"
    assert 'setpoints_2022.txt' in content, "2022 backup inner file setpoints_2022.txt missing"
