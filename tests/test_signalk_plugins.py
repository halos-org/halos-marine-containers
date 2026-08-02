"""Tests for the curated Signal K plugin manifest.

The manifest is read at runtime by apps/signalk-server/provision.sh, which logs a
warning and moves on when an entry fails to install. A typo therefore ships
silently, so the manifest is validated here instead.
"""

import re
from pathlib import Path

import pytest

APP_DIR = Path(__file__).parent.parent / "apps" / "signalk-server"
MANIFEST = APP_DIR / "assets" / "plugins.list"

# npm package name, optionally scoped: @scope/name or name.
NPM_NAME = re.compile(r"^(@[a-z0-9][a-z0-9._-]*/)?[a-z0-9][a-z0-9._-]*$")


def manifest_entries() -> list[str]:
    """Parse the manifest the same way provision.sh does."""
    entries = []
    for line in MANIFEST.read_text().splitlines():
        entry = line.split("#", 1)[0].strip()
        if entry:
            entries.append(entry)
    return entries


def test_manifest_is_packaged():
    """It must live under assets/, which is the only path the packaging tool
    installs. A manifest at the app root is copied by nothing and the seed loop
    silently finds no file."""
    assert MANIFEST.is_file()
    assert not (APP_DIR / "plugins.list").exists()


def test_entries_are_valid_npm_names():
    for entry in manifest_entries():
        assert NPM_NAME.match(entry), f"not a valid npm package name: {entry!r}"


def test_no_duplicate_entries():
    entries = manifest_entries()
    duplicates = {e for e in entries if entries.count(e) > 1}
    assert not duplicates, f"duplicate entries: {sorted(duplicates)}"


def test_influxdb_plugin_is_present():
    """prestart.sh writes the InfluxDB token config only when this plugin is
    installed, so dropping it from the manifest silently disables logging."""
    assert "signalk-to-influxdb2" in manifest_entries()


def test_webapps_are_ordered_first():
    """Provisioning installs in manifest order and can run out of its per-boot
    budget, so the webapps a chartplotter needs must not sit behind the long
    tail. Anything reordered past them loses that guarantee silently."""
    entries = manifest_entries()
    webapps = ["@signalk/freeboard-sk", "@halos-org/skip", "@signalk/charts-plugin"]

    for webapp in webapps:
        assert webapp in entries, f"expected webapp missing: {webapp}"
    positions = [entries.index(w) for w in webapps]
    assert positions == sorted(positions)
    assert max(positions) < len(entries) / 2


def test_manifest_has_no_crlf():
    """provision.sh strips CR defensively, but .gitattributes pins LF so a
    Windows checkout cannot introduce them in the first place."""
    assert b"\r" not in MANIFEST.read_bytes()


@pytest.mark.parametrize("script", ["provision.sh", "prestart.sh"])
def test_scripts_are_executable(script):
    assert APP_DIR.joinpath(script).stat().st_mode & 0o111


def test_prestart_no_longer_seeds_plugins():
    """Seeding moved to provision.sh so it runs outside the app unit's start
    path. If it reappears here it is back inside the blocking ExecStartPre whose
    timeout killed it mid-install."""
    prestart = (APP_DIR / "prestart.sh").read_text()

    assert "plugins.list" not in prestart
    assert "--entrypoint npm" not in prestart
    assert "install --prefix" not in prestart


def test_prestart_chown_is_scoped():
    """A recursive chown of the data root walks the whole plugin tree and the npm
    cache on every boot, inside the same start budget the seeding was moved out
    of ExecStartPre to protect."""
    prestart = (APP_DIR / "prestart.sh").read_text()

    assert 'chown -R 1000:1000 "${CONTAINER_DATA_ROOT}"' not in prestart


def test_provision_uses_the_framework_container_name():
    """The unit reaps this exact name in ExecStopPost after a start timeout. A
    hook that names its container anything else leaves an installer running
    against the data volume."""
    provision = (APP_DIR / "provision.sh").read_text()

    assert '--name "${HALOS_PROVISION_CONTAINER}"' in provision
    assert 'docker rm -f "${HALOS_PROVISION_CONTAINER}"' in provision
