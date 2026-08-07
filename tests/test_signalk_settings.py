"""Tests for the Signal K settings seeded into a new data volume.

These assertions cover the *hand-authored* form of the gpsd connection, where
this repo spells out `pipeElements` itself. Signal K also accepts the connection
as a single `providers/simple` element, which assembles the same pipeline
internally and would make the line splitter automatic; if the baked config ever
moves to that form, these checks stop applying and should move with it rather
than be forced to pass.
"""

import json
from pathlib import Path

import pytest

SETTINGS = (
    Path(__file__).parent.parent
    / "apps"
    / "signalk-server"
    / "default-data"
    / "data"
    / "settings.json"
)

# The gpsd daemon's own default, and what the host service listens on. Signal K
# runs with network_mode: host, so localhost here is the host's gpsd.
GPSD_HOST = "localhost"
GPSD_PORT = 2947


@pytest.fixture
def settings():
    with open(SETTINGS) as f:
        return json.load(f)


def gpsd_provider(settings):
    providers = [p for p in settings["pipedProviders"] if p["id"] == "gpsd"]
    assert len(providers) == 1, "expected exactly one gpsd provider"
    return providers[0]


def hand_authored_elements(provider):
    """Element types, or a skip when the connection is not hand-authored."""
    types = [e["type"] for e in provider["pipeElements"]]
    if "providers/simple" in types:
        pytest.skip("connection is built by providers/simple, which adds its own liner")
    return types


def test_gpsd_pipeline_splits_lines_before_parsing(settings):
    """gpsd writes a whole NMEA reporting cycle in one TCP write.

    Without a splitter between the source and the parser, nmea0183-signalk sees
    several sentences as one unparseable blob and position never arrives -- only
    a sentence that happens to land alone in a write gets through. Verified
    against the pinned server: one CRLF-terminated ZDA+GGA+RMC burst delivered
    as a single write produces one delta without the liner and three, including
    navigation.position, with it.

    Upstream inserts the Liner for gpsd connections built through
    providers/simple, and has since v2.25.0. A hand-authored pipeElements array
    bypasses that branch, so no amount of upgrading signalk-server can supply it.
    """
    elements = hand_authored_elements(gpsd_provider(settings))

    assert "providers/liner" in elements, (
        "gpsd connection has no line splitter; multi-sentence writes will not parse"
    )
    assert elements.index("providers/gpsd") < elements.index("providers/liner")
    assert elements.index("providers/liner") < elements.index(
        "providers/nmea0183-signalk"
    ), "the liner must sit between the gpsd source and the NMEA parser"


def test_gpsd_connection_points_at_the_host_daemon(settings):
    """A wrong endpoint costs the position as completely as a missing splitter."""
    elements = gpsd_provider(settings)["pipeElements"]
    source = next(e for e in elements if e["type"] == "providers/gpsd")
    options = source.get("options", {})

    assert options.get("hostname", options.get("host")) == GPSD_HOST
    assert options.get("port") == GPSD_PORT


def test_gpsd_connection_is_enabled(settings):
    """Signal K treats a missing `enabled` key as enabled, so only False is wrong."""
    provider = gpsd_provider(settings)

    assert provider.get("enabled", True) is not False, (
        "the gpsd connection is disabled, so no position will be produced"
    )
