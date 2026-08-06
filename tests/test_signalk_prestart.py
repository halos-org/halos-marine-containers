"""Tests for the Signal K Server app's prestart hook.

The curated plugin set is baked into the image (halos-org/signalk-server-docker)
and verified there. What is left in this repo is the hook that runs as root
before the container starts: it writes the files holding the admin hash, the JWT
signing key and the InfluxDB token, and it hands the data volume over to the
container's uid.
"""

import re
import subprocess
from pathlib import Path

APP_DIR = Path(__file__).parent.parent / "apps" / "signalk-server"


def test_prestart_is_executable():
    assert APP_DIR.joinpath("prestart.sh").stat().st_mode & 0o111


def test_prestart_hook_behaves():
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


def test_prestart_does_not_install_plugins():
    """Plugins are baked into the image, so nothing here may reach for npm.

    Runtime installation was tried twice and failed twice: from inside this hook,
    where the app unit's start budget killed it mid-install, and from a
    provisioning one-shot, which put the navigation server behind the npm
    registry on every package upgrade.
    """
    prestart = (APP_DIR / "prestart.sh").read_text()

    assert "plugins.list" not in prestart
    assert "--entrypoint npm" not in prestart
    assert "install --prefix" not in prestart


def test_prestart_chown_is_scoped():
    """A recursive chown over any ancestor of node_modules walks the whole plugin
    tree on every boot, inside the app unit's start budget.

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


def test_prestart_does_not_gate_influxdb_on_the_data_volume():
    """The plugin lives in the image, so the data volume cannot attest to it.

    A presence check under the data volume's node_modules is false on every
    device that has not updated the plugin through the app store -- which is
    every device on a fresh install -- and the token config is then never
    written. Silent: the server starts, and only the graphs are empty.
    """
    prestart = (APP_DIR / "prestart.sh").read_text()

    assert "node_modules/signalk-to-influxdb2" not in prestart
