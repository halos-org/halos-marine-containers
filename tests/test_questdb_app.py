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


def test_commit_mode_is_overridable():
    """The choice between nosync and sync is about the host's power path.

    nosync leaves durability to the OS page cache, so an unclean shutdown can
    land a commit record while the partition data it describes is still dirty.
    The table then claims rows that are not on disk and QuestDB fails while
    opening the partition -- a state no RESUME WAL variant repairs, because the
    failure happens before any transaction is read. It costs the whole table,
    not the last few seconds.

    HALPI2 carries supercapacitors, so loss of supply becomes an orderly
    shutdown and the remaining causes are a kernel panic, a watchdog reset or a
    device pulled live. nosync is the call for that hardware and the wrong one
    for a board that simply stops when the supply does, so the value has to
    stay reachable from the app's config rather than being pinned in payload
    the next upgrade overwrites.
    """
    mode = _environment().get("QDB_CAIRO_COMMIT_MODE")
    assert mode == "${QUESTDB_COMMIT_MODE:-nosync}", (
        "the commit mode must interpolate a config field; a literal here "
        "cannot be changed through /etc/container-apps/questdb/env"
    )

    with open(APP_DIR / "config.yml") as f:
        config = yaml.safe_load(f)
    fields = {f["id"]: f for group in config["groups"] for f in group["fields"]}
    assert fields["QUESTDB_COMMIT_MODE"]["default"] in ("nosync", "sync"), (
        "QuestDB ignores an unknown value here and runs its own default"
    )


def test_no_worker_setting_carries_the_cairo_prefix():
    """QuestDB ignores an environment variable whose name it does not know.

    It validates server.conf strictly and refuses to start on an unrecognised
    key there, but the environment is never checked: a misnamed QDB_ variable
    leaves the container healthy, recording, answering queries, and running the
    default the setting was meant to replace. QDB_CAIRO_WAL_APPLY_WORKER_COUNT
    shipped that way from this app's first commit -- the property is
    wal.apply.worker.count, with no cairo. prefix -- and nothing surfaced it
    until someone counted threads on a device.

    So the wrong name is the thing to assert against, not the right one.
    """
    for key in _environment():
        assert not key.startswith("QDB_CAIRO_WAL_APPLY_"), (
            f"{key} is not a QuestDB property: the wal.apply.* pool takes no "
            "cairo. prefix, and QuestDB ignores the variable without a word"
        )


def test_every_thread_pool_that_starts_workers_is_sized_and_slept():
    """A pool left out of either list keeps QuestDB's defaults.

    Both defaults are wrong for this deployment. The worker count comes from
    the core count, so a 4-core board gets two threads for pools this stack
    never exercises; the sleep threshold is 10000 poll cycles, which burns CPU
    whether or not rows arrive. Neither has a global override -- the settings
    are per pool, and a pool nobody thought of is a pool still spinning.

    QDB_SHARED_WORKER_COUNT is the one count covering more than its own pool:
    the network, query and write pools each fall back to it.
    """
    env = _environment()
    pools = [
        "WAL_APPLY",
        "LINE_TCP_IO",
        "LINE_TCP_WRITER",
        "VIEW_COMPILER",
        "MAT_VIEW_REFRESH",
        "LIVE_VIEW_REFRESH",
    ]
    for pool in pools:
        assert f"QDB_{pool}_WORKER_COUNT" in env, (
            f"the {pool} pool has no worker count, so QuestDB sizes it from "
            "the core count"
        )
    for pool in pools + ["SHARED", "EXPORT"]:
        assert env.get(f"QDB_{pool}_WORKER_SLEEP_THRESHOLD") == "100", (
            f"the {pool} pool has no sleep threshold, so its workers spin "
            "10000 cycles before sleeping"
        )


def test_log_level_is_overridable_and_keeps_critical():
    """ERROR hides the INFO band that precedes a table suspension.

    A level is a floor rather than an exact set, so ERROR still carries
    CRITICAL and ADVISORY -- suspension and the max_map_count warning survive.
    The WAL apply memory-pressure backoff does not, and that is the warning a
    boat needs when recording stalls with the server healthy. The value has to
    stay reachable from the app's config so an operator can raise it without
    editing package payload that the next upgrade overwrites.

    CRITICAL would read as merely stricter and is not: it drops the ERROR band
    with ILP parse failures and non-tolerable apply errors in it.
    """
    level = _environment().get("QDB_LOG_W_STDOUT_LEVEL")
    assert level == "${QUESTDB_LOG_LEVEL:-ERROR}", (
        "the log level must interpolate a config field; a literal here cannot "
        "be changed through /etc/container-apps/questdb/env"
    )

    with open(APP_DIR / "config.yml") as f:
        config = yaml.safe_load(f)
    fields = {f["id"]: f for group in config["groups"] for f in group["fields"]}
    assert fields["QUESTDB_LOG_LEVEL"]["default"] in ("ERROR", "INFO"), (
        "CRITICAL drops the ERROR band, which carries ILP parse failures"
    )


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
