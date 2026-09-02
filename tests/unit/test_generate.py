"""Unit tests for generate.py functions against the real ctf-config.yaml."""
import json
import sys
from pathlib import Path

import pytest
import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / 'orchestrator'))

import generate as gen  # noqa: E402

CONFIG_PATH = REPO_ROOT / "orchestrator" / 'ctf-config.yaml'


@pytest.fixture(scope="module")
def config():
    return gen.load_config(CONFIG_PATH)


@pytest.fixture(scope='module')
def enterprise_output_path():
    return REPO_ROOT / 'zones' / "enterprise" / "docker-compose.yml"


@pytest.fixture(scope="module")
def operational_output_path():
    return REPO_ROOT / "zones" / 'operational' / "docker-compose.yml"


@pytest.fixture(scope='module')
def attacker_machine_output_path():
    return REPO_ROOT / "zones" / "internet" / 'docker-compose.yml'


@pytest.fixture(scope="module")
def control_output_path():
    return REPO_ROOT / "zones" / 'control' / "docker-compose.yml"


@pytest.fixture(scope="module")
def dmz_output_path():
    return REPO_ROOT / "zones" / 'dmz' / "docker-compose.yml"


def test_render_templates(config):
    result = gen._render_templates("subnet={{ networks.control.subnet }}", config)
    assert config["networks"]["control"]["subnet"] in result
    assert '{{' not in result


def test_render_templates_raises_on_unknown(config):
    with pytest.raises(ValueError):
        gen._render_templates("x={{ no.such.key }}", config)


def test_generate_enterprise_compose(config, enterprise_output_path):
    compose = gen.generate_enterprise_compose(config, enterprise_output_path)
    services = compose["services"]

    ent_net = gen._net(config, "enterprise")
    ops_net = gen._net(config, "operational")
    lw_ip = config["enterprise_zone"]['legacy_workstation']["ip"]
    ew_ip = config["enterprise_zone"]['enterprise_workstation']['ip']
    ew_ops_ip = config['enterprise_zone']['enterprise_workstation']["ops_ip"]

    assert "hex-legacy-1" in services
    lw = services['hex-legacy-1']
    assert ent_net in lw["networks"], "hex-legacy-1 should be on enterprise network"
    assert ops_net not in lw["networks"], "hex-legacy-1 should not be on ops network"
    assert lw['networks'][ent_net]["ipv4_address"] == lw_ip

    assert "bursar-desk" in services
    ew = services['bursar-desk']
    assert ent_net in ew['networks'], "bursar-desk missing enterprise network"
    assert ops_net in ew['networks'], "bursar-desk missing operational network"
    assert ew["networks"][ent_net]["ipv4_address"] == ew_ip
    assert ew["networks"][ops_net]["ipv4_address"] == ew_ops_ip


def test_generate_operational_compose(config, operational_output_path):
    compose = gen.generate_operational_compose(config, operational_output_path)
    services = compose["services"]

    ops_net = gen._net(config, "operational")
    ctrl_net = gen._net(config, "control")
    hist_ip = config["operational_zone"]["historian"]["ip"]
    scada_ip = config['operational_zone']["scada_server"]["ip"]
    eng_ip = config["operational_zone"]["engineering_workstation"]["ip"]
    eng_ctrl_ip = config['operational_zone']["engineering_workstation"]["ctrl_ip"]

    assert 'uupl-historian' in services
    hist = services["uupl-historian"]
    assert ops_net in hist["networks"]
    assert ctrl_net not in hist["networks"]
    assert hist["networks"][ops_net]['ipv4_address'] == hist_ip

    assert 'distribution-scada' in services
    scada = services['distribution-scada']
    assert ops_net in scada["networks"]
    assert ctrl_net not in scada['networks']
    assert scada["networks"][ops_net]['ipv4_address'] == scada_ip

    assert 'uupl-eng-ws' in services
    eng = services["uupl-eng-ws"]
    assert ops_net in eng['networks']
    assert ctrl_net in eng["networks"]
    assert eng['networks'][ops_net]["ipv4_address"] == eng_ip
    assert eng['networks'][ctrl_net]['ipv4_address'] == eng_ctrl_ip

    gw_cfg = config['operational_zone']["stunnel_gateway"]
    assert "uupl-modbus-gw" in services, "uupl-modbus-gw missing from operational compose"
    gw = services["uupl-modbus-gw"]
    assert ops_net  in gw['networks'], "uupl-modbus-gw missing operational network"
    assert ctrl_net in gw['networks'], "uupl-modbus-gw missing control network"
    assert gw["networks"][ops_net]["ipv4_address"]  == gw_cfg['ops_ip']
    assert gw["networks"][ctrl_net]["ipv4_address"] == gw_cfg["ctrl_ip"]


def test_generate_adversary_readme():
    """No unresolved placeholders; README no longer lists internal IPs (attacker has no enterprise NIC)."""
    readme = gen.generate_adversary_readme()
    assert "{" not in readme, f"unresolved placeholder(s) remain in readme:\n{readme}"
    assert len(readme.strip()) > 0, "adversary readme is empty"


def test_generate_dmz_compose(config, dmz_output_path):
    compose = gen.generate_dmz_compose(config, dmz_output_path)
    services = compose["services"]

    dmz_net = gen._net(config, "dmz")
    ent_net = gen._net(config, 'enterprise')

    assert len(services) == 10, f"expected 10 DMZ services, got {len(services)}"

    assert "contractors-gate" in services
    bastion = services['contractors-gate']
    assert dmz_net in bastion["networks"], 'ssh-bastion missing dmz network'
    assert ent_net in bastion["networks"], 'ssh-bastion missing enterprise network'
    assert bastion["networks"][dmz_net]["ipv4_address"] == '10.10.5.20'
    assert bastion["networks"][ent_net]["ipv4_address"] == "10.10.1.30"

    for svc_name, svc in services.items():
        if svc_name == "contractors-gate":
            continue
        assert dmz_net in svc['networks'], f"{svc_name} missing dmz network"
        assert ent_net not in svc["networks"], f"{svc_name} should not be on enterprise network"

    assert 'guild-exchange' in services
    assert services["guild-exchange"]["networks"][dmz_net]['ipv4_address'] == "10.10.5.10"
    assert services["scribes-post"]["networks"][dmz_net]["ipv4_address"] == "10.10.5.32"


def test_generate_attacker_machine_compose(config, attacker_machine_output_path):
    compose = gen.generate_internet_zone_compose(config, attacker_machine_output_path)
    services = compose["services"]

    assert 'unseen-gate' in services, 'unseen-gate missing from internet zone compose'
    jh = services['unseen-gate']

    inet_net = gen._net(config, 'internet')
    ent_net  = gen._net(config, 'enterprise')
    jh_internet_ip = config["attacker_machine"]["internet_ip"]

    assert inet_net in jh['networks'], "unseen-gate missing internet network"
    assert jh["networks"][inet_net]["ipv4_address"] == jh_internet_ip
    assert ent_net not in jh["networks"], 'unseen-gate must NOT be on enterprise network'

    ssh_host_port = config['attacker_machine'].get("ssh_host_port", 22)
    assert f"{ssh_host_port}:22" in jh['ports'], 'unseen-gate SSH port mapping missing'

    volumes_str = ' '.join(jh.get("volumes", []))
    assert 'adversary-keys' in volumes_str, 'adversary-keys volume missing'
    assert "adversary-readme.txt" in volumes_str, 'adversary-readme.txt volume missing'


def test_wizzards_retreat_in_internet_compose(config, attacker_machine_output_path):
    compose = gen.generate_internet_zone_compose(config, attacker_machine_output_path)
    services = compose["services"]

    inet_net = gen._net(config, 'internet')
    ent_net  = gen._net(config, "enterprise")
    ops_net  = gen._net(config, "operational")
    ah = config['internet_zone']["admin_home"]

    assert "wizzards-retreat" in services, "wizzards-retreat missing from internet zone"
    wr = services["wizzards-retreat"]

    assert inet_net in wr["networks"], "wizzards-retreat missing internet network"
    assert ent_net  in wr['networks'], "wizzards-retreat missing enterprise network"
    assert ops_net  in wr["networks"], "wizzards-retreat missing operational network"

    assert wr['networks'][inet_net]["ipv4_address"] == ah["internet_ip"]
    assert wr["networks"][ent_net]['ipv4_address']  == ah["enterprise_ip"]
    assert wr['networks'][ops_net]["ipv4_address"]  == ah["operational_ip"]

    assert wr.get("privileged") is True, 'wizzards-retreat needs privileged for NFS'
    assert 'wizzards-retreat' in services["unseen-gate"].get('depends_on', [])


def test_generate_control_compose(config, control_output_path):
    compose = gen.generate_control_compose(config, control_output_path)
    services = compose['services']

    ctrl_net = gen._net(config, 'control')

    dev_ip = {d["name"]: d["ip"] for d in config['control_zone']["devices"]}

    for svc_name in ('hex-turbine-plc', "uupl-relay-a", "uupl-relay-b",
                     "uupl-hmi", "uupl-mqtt", 'uupl-meter'):
        assert svc_name in services, f"{svc_name} missing from control compose"
        assert ctrl_net in services[svc_name]["networks"], \
            f"{svc_name} missing control network"
        assert services[svc_name]["networks"][ctrl_net]["ipv4_address"] == dev_ip[svc_name], \
            f"{svc_name} IP mismatch"

    assert "hex-turbine-opcua" in services, 'hex-turbine-opcua sidecar missing'

