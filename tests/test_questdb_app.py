"""Tests for the QuestDB container app definition.

QuestDB's open-source build authenticates nothing: the HTTP console is an
unrestricted SQL client and the ILP and PostgreSQL ports take any caller. What
keeps that safe here is the app definition itself, and every property below
fails silently if it regresses -- the container still starts, still records, and
still answers queries.
"""

from pathlib import Path

import yaml

APP_DIR = Path(__file__).parent.parent / "apps" / "questdb"

# QuestDB memory-maps every partition column file and every WAL segment.
RECOMMENDED_MAX_MAP_COUNT = 1048576


def _compose() -> dict:
    with open(APP_DIR / "docker-compose.yml") as f:
        return yaml.safe_load(f)


def _metadata() -> dict:
    with open(APP_DIR / "metadata.yaml") as f:
        return yaml.safe_load(f)


def _service() -> dict:
    services = _compose()["services"]
    assert len(services) == 1, "one service, so the port assertions below cover it"
    return next(iter(services.values()))


def _environment() -> dict[str, str]:
    env = _service().get("environment", [])
    return dict(item.split("=", 1) for item in env)


def test_every_published_port_is_loopback_only():
    """No port of QuestDB's authenticates anything, on any protocol.

    Publishing any of them on a wildcard address hands the vessel's history to
    the whole boat network with no credential in the way. This covers the
    device's own interfaces only -- containers on halos-proxy-network reach
    every container port regardless of what is published here.
    """
    for mapping in _service()["ports"]:
        host_ip, host_port, _container_port = mapping.split(":")
        assert host_ip == "127.0.0.1", (
            f"port {host_port} is published on {host_ip}; QuestDB authenticates "
            "nothing, so no port may leave the host's loopback interface"
        )


def test_commit_mode_is_sync():
    """QuestDB's default leaves durability to the OS page cache.

    A power cut can then land a commit record while the partition data it
    describes is still dirty. The table claims rows that are not on disk and
    QuestDB fails while opening the partition -- a state no RESUME WAL variant
    repairs, because the failure happens before any transaction is read. Boats
    lose power; this is the deployment, not an edge case.
    """
    assert _environment().get("QDB_CAIRO_COMMIT_MODE") == "sync"


def test_prestart_raises_max_map_count():
    """The stock limit of 65530 exhausts on a grown database.

    mmap then fails while RAM is still free: queries error and WAL apply
    suspends. The limit is kernel-global rather than per-namespace, so no
    container flag reaches it and the host has to be configured.
    """
    prestart = (APP_DIR / "prestart.sh").read_text()

    assert "vm.max_map_count" in prestart
    assert str(RECOMMENDED_MAX_MAP_COUNT) in prestart


def test_console_is_gated_by_forward_auth():
    """The console is a full SQL client and can drop tables.

    Authelia is the whole gate: QuestDB has no login of its own, so nothing
    below forward_auth protects it. Mode "none" -- which InfluxDB can afford,
    because InfluxDB authenticates its own UI -- would publish it outright, and
    "oidc" would claim a native OAuth integration QuestDB does not have.
    """
    auth_mode = _metadata()["routing"]["auth"]["mode"]

    assert auth_mode == "forward_auth"
