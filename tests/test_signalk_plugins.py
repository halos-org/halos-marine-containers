"""Tests for the curated Signal K plugin manifest.

The manifest is read at runtime by apps/signalk-server/provision.sh. An entry the
registry will never serve makes it exit non-zero, and Signal K requires that unit
after an install or upgrade -- so a typo here withholds the app on every device
that has not yet provisioned this package version.
"""

import re
import subprocess
import urllib.error
import urllib.request
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


def test_entries_exist_in_the_registry():
    """A typo that is still a legal npm name passes every other check here, and
    now stops the app: provision.sh gives up on a 404, and Signal K Requires=
    that unit. One character in this file would otherwise take down every device
    that has not already provisioned."""
    for entry in manifest_entries():
        url = f"https://registry.npmjs.org/{entry}"
        try:
            with urllib.request.urlopen(url, timeout=30) as response:
                assert response.status == 200, f"{entry}: HTTP {response.status}"
        except urllib.error.HTTPError as exc:
            if exc.code == 404:
                raise AssertionError(f"{entry} is not in the npm registry") from exc
            pytest.skip(f"registry returned HTTP {exc.code} for {entry}")
        except urllib.error.URLError as exc:
            pytest.skip(f"npm registry unreachable: {exc.reason}")


def test_no_duplicate_entries():
    entries = manifest_entries()
    duplicates = {e for e in entries if entries.count(e) > 1}
    assert not duplicates, f"duplicate entries: {sorted(duplicates)}"


def test_influxdb_plugin_is_present():
    """prestart.sh writes the InfluxDB token config only when this plugin is
    installed, so dropping it from the manifest silently disables logging."""
    assert "signalk-to-influxdb2" in manifest_entries()




def test_manifest_has_no_crlf():
    """provision.sh strips CR defensively, but .gitattributes pins LF so a
    Windows checkout cannot introduce them in the first place."""
    assert b"\r" not in MANIFEST.read_bytes()


@pytest.mark.parametrize("script", ["provision.sh", "prestart.sh"])
def test_scripts_are_executable(script):
    assert APP_DIR.joinpath(script).stat().st_mode & 0o111


def test_provision_hook_behaves(tmp_path):
    """Run the hook against stubbed docker/dpkg-query.

    Everything that decides whether a boot costs nothing or blocks Signal K
    indefinitely lives in that script, and no assertion on its text reaches it.
    """
    harness = Path(__file__).parent.parent / "tools" / "test-provision.sh"

    result = subprocess.run(
        ["bash", str(harness)], capture_output=True, text=True, timeout=180
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_prestart_hook_behaves(tmp_path):
    """Run the hook against a sandbox with stubbed chown/bcrypt.

    It writes the admin hash, the JWT key and the InfluxDB token. Their modes are
    a property of the filesystem after it runs, which no assertion on the
    script's text reaches.
    """
    harness = Path(__file__).parent.parent / "tools" / "test-prestart.sh"

    result = subprocess.run(
        ["bash", str(harness)], capture_output=True, text=True, timeout=120
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_prestart_no_longer_seeds_plugins():
    """Seeding moved to provision.sh so it runs outside the app unit's start
    path. If it reappears here it is back inside the blocking ExecStartPre whose
    timeout killed it mid-install."""
    prestart = (APP_DIR / "prestart.sh").read_text()

    assert "plugins.list" not in prestart
    assert "--entrypoint npm" not in prestart
    assert "install --prefix" not in prestart


def test_prestart_chown_is_scoped():
    """A recursive chown over any ancestor of node_modules walks the whole plugin
    tree and the npm cache on every boot, inside the app unit's start budget.

    Parsed rather than pattern-matched: the target is only the second token when
    no flags sit between `-R` and the owner, and SIGNALK_DATA contains
    node_modules just as surely as the data root does.
    """
    prestart = (APP_DIR / "prestart.sh").read_text()

    calls = re.findall(r"chown\s+((?:-\S+\s+)*)\S+\s+(\S+)", prestart)
    assert calls, "no chown call parsed -- the guard would pass vacuously"
    recursive_targets = [target for flags, target in calls if "R" in flags]
    forbidden = {"CONTAINER_DATA_ROOT", "SIGNALK_DATA"}
    for target in recursive_targets:
        referenced = set(re.findall(r"\$\{?(\w+)", target))
        assert not (referenced & forbidden), (
            f"recursive chown over {target} walks node_modules"
        )


