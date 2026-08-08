"""Tests for the Signal K settings seeded into a new data volume."""

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

# gpsd's own default port, and what the host service listens on. Signal K runs
# with network_mode: host, so localhost here is the host's gpsd.
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


def test_gpsd_connection_is_assembled_by_the_server(settings):
    """The pipeline must be built by providers/simple, not spelled out here.

    Signal K assembles a gpsd connection as Gpsd -> Liner -> nmea0183-signalk.
    The Liner matters: gpsd writes a whole NMEA reporting cycle in one TCP
    write, and without a splitter the parser receives several sentences as one
    blob and rejects all of them. Verified against the pinned image with a gpsd
    that writes ZDA+GGA+RMC in a single write: spelled out by hand without a
    liner, the parser logs one error whose content is all three sentences
    concatenated; through providers/simple, all three parse.

    Spelling the elements out here means the pipeline stops tracking upstream --
    that is exactly how the Liner came to be missing, and no server upgrade
    could supply it. It also costs operator control: the server marks a
    connection editable only when it is a single providers/simple element, so a
    hand-authored one appears in the admin UI as a read-only box whose only
    action is Delete.
    """
    elements = gpsd_provider(settings)["pipeElements"]

    assert len(elements) == 1, (
        "the gpsd connection must be one providers/simple element; spelling out "
        "the pipeline stops it tracking upstream and makes it uneditable"
    )
    assert elements[0]["type"] == "providers/simple"

    options = elements[0]["options"]
    assert options["type"] == "NMEA0183"
    assert options["subOptions"]["type"] == "gpsd"


def test_gpsd_connection_points_at_the_host_daemon(settings):
    """A wrong endpoint costs the position as completely as a missing splitter."""
    sub = gpsd_provider(settings)["pipeElements"][0]["options"]["subOptions"]

    # `host`, not `hostname`: the admin UI writes `host`, and the server reads
    # `hostname ?? host`, so a baked `hostname` would silently override any
    # later edit made through the UI.
    assert "hostname" not in sub, "bake `host`; `hostname` shadows UI edits"
    assert sub["host"] == GPSD_HOST
    assert sub["port"] == GPSD_PORT


def test_gpsd_connection_is_enabled(settings):
    """Signal K treats a missing `enabled` key as enabled, so only False is wrong."""
    provider = gpsd_provider(settings)

    assert provider.get("enabled", True) is not False, (
        "the gpsd connection is disabled, so no position will be produced"
    )
