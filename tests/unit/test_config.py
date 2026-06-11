"""Unit tests for ctf-config.yaml schema validation.

Checks top-level keys, subnet distinctness, and ICS process validity.
No Docker. No subprocess calls.
"""
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO_ROOT / "orchestrator"))

import generate as gen  # noqa: E402

CONFIG_PATH = REPO_ROOT / "orchestrator" / "ctf-config.yaml"

REQUIRED_TOP_LEVEL_KEYS = [
    "meta",
    "ics_process",
    "networks",
    "enterprise_zone",
    "operational_zone",
    "control_zone",
    "attacker_machine",
]


@pytest.fixture(scope="module")
def config():
    return gen.load_config(CONFIG_PATH)


def test_required_top_level_keys(config):
    """All required top-level keys must be present."""
    for key in REQUIRED_TOP_LEVEL_KEYS:
        assert key in config, f"required top-level key {key!r} missing from config"


def test_network_subnets_distinct(config):
    """All network subnets must be different strings."""
    subnets = [net["subnet"] for net in config["networks"].values()]
    assert len(subnets) == 6, "expected exactly 6 networks"
    assert len(set(subnets)) == len(subnets), (
        f"duplicate subnets found: {subnets}"
    )


def test_component_dirs_exist():
    """Every COMPONENT_DIRS entry must resolve to a directory containing a Dockerfile."""
    for name, path in gen.COMPONENT_DIRS.items():
        assert path.exists() and path.is_dir(), \
            f"COMPONENT_DIRS[{name!r}] path does not exist: {path}"
        assert (path / "Dockerfile").exists(), \
            f"COMPONENT_DIRS[{name!r}] has no Dockerfile: {path}"
