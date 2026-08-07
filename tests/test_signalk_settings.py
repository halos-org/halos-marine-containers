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


@pytest.fixture
def settings():
    with open(SETTINGS) as f:
        return json.load(f)


def gpsd_pipe_elements(settings):
    """The pipeElements of the baked gpsd connection."""
    providers = [p for p in settings["pipedProviders"] if p["id"] == "gpsd"]
    assert len(providers) == 1, "expected exactly one gpsd provider"
    return [e["type"] for e in providers[0]["pipeElements"]]


def test_gpsd_pipeline_splits_lines_before_parsing(settings):
    """gpsd writes a whole NMEA reporting cycle in one TCP write.

    Without a liner between the source and the parser, nmea0183-signalk sees
    several sentences as one unparseable blob and position never arrives -- only
    a sentence that happens to land alone in a write gets through. Upstream adds
    the Liner for gpsd connections built through the admin UI (providers/simple),
    which this hand-authored pipeElements array bypasses entirely, so upgrading
    signalk-server cannot fix it.
    """
    elements = gpsd_pipe_elements(settings)

    assert "providers/liner" in elements, (
        "gpsd connection has no line splitter; multi-sentence writes will not parse"
    )
    assert elements.index("providers/gpsd") < elements.index("providers/liner")
    assert elements.index("providers/liner") < elements.index(
        "providers/nmea0183-signalk"
    ), "the liner must sit between the gpsd source and the NMEA parser"


def test_gpsd_connection_is_enabled(settings):
    providers = [p for p in settings["pipedProviders"] if p["id"] == "gpsd"]
    assert providers[0]["enabled"] is True
