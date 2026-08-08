"""Tests for the Signal K Server app's prestart hook.

The curated plugin set is baked into the image (halos-org/signalk-server-docker)
and verified there. What is left in this repo is the hook that runs as root
before the container starts: it writes the files holding the admin hash, the JWT
signing key and the InfluxDB token, and it hands the data volume over to the
container's uid.
"""

import json
import re
import subprocess
import urllib.error
import urllib.request
from pathlib import Path

import pytest

APP_DIR = Path(__file__).parent.parent / "apps" / "signalk-server"

# The hook's text, minus comments. The guards below are substring checks, and
# this repo's house style puts long explanations right above the code they
# justify -- matching those would make the guards fire on prose and quietly
# discourage documenting the very decisions they exist to protect.
def hook_code() -> str:
    lines = (APP_DIR / "prestart.sh").read_text().splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("#"))


def test_image_is_the_baked_one_at_an_exact_tag():
    """The plugins live in the image, so this pin is the only thing tying the
    device to a verified build.

    Nothing else in this repo can see the plugin set. Point this line back at
    upstream and every test here still passes while every curated plugin
    disappears and prestart.sh writes an InfluxDB config for a plugin that is
    not installed. A floating tag is the same failure with an extra step: the
    curated set is resolved unpinned at build time, so a rebuild behind a moving
    tag swaps the image underneath a verification that already passed.
    """
    compose = (APP_DIR / "docker-compose.yml").read_text()
    refs = re.findall(r"^\s*image:\s*(\S+)", compose, re.MULTILINE)
    assert len(refs) == 1, f"expected exactly one image, got {refs}"

    repo, _, tag = refs[0].partition(":")
    assert repo == "ghcr.io/halos-org/signalk-server-docker", (
        f"not the baked image: {refs[0]}"
    )
    # v<upstream version>-halos.<build revision>, the shape
    # signalk-server-docker publishes. The `-halos.` separator is what tells
    # upstream's version from our build revision; anything reading the tag
    # splits on it. Rejects latest, a bare version, and any moving alias.
    assert re.fullmatch(r"v\d+\.\d+\.\d+-halos\.\d+", tag), (
        f"not an exact tag: {tag!r}"
    )


def test_image_exists_in_the_registry():
    """A well-formed tag that was never published passes every other check here,
    ships a .deb, and lands every device in a terminal `failed` unit.

    This one line is the whole plugin set, and the shape check above cannot see
    the artifact. An off-by-one revision, or a repin made ahead of the image
    repo's merge, is a realistic mistake -- that repo's CI refuses to overwrite a
    published tag, so "repin first, publish later" is an ordering people hit.
    Replaces the registry half of the deleted manifest tests, and skips on a
    network failure the same way they did.
    """
    compose = (APP_DIR / "docker-compose.yml").read_text()
    ref = re.search(r"^\s*image:\s*(\S+)", compose, re.MULTILINE).group(1)
    repo, _, tag = ref.partition(":")
    path = repo.removeprefix("ghcr.io/")

    try:
        with urllib.request.urlopen(
            f"https://ghcr.io/token?scope=repository:{path}:pull", timeout=30
        ) as response:
            token = json.load(response)["token"]
        request = urllib.request.Request(
            f"https://ghcr.io/v2/{path}/manifests/{tag}", method="HEAD"
        )
        request.add_header("Authorization", f"Bearer {token}")
        # Anonymous, deliberately: the devices pull without credentials, so a
        # package that went private has to fail here rather than pass on a
        # maintainer's token.
        request.add_header(
            "Accept",
            "application/vnd.oci.image.manifest.v1+json,"
            "application/vnd.docker.distribution.manifest.v2+json",
        )
        with urllib.request.urlopen(request, timeout=30) as response:
            assert response.status == 200, f"{ref}: HTTP {response.status}"
    except urllib.error.HTTPError as exc:
        raise AssertionError(
            f"{ref} is not anonymously pullable from the registry (HTTP {exc.code})"
        ) from exc
    except urllib.error.URLError as exc:
        pytest.skip(f"registry unreachable: {exc.reason}")


def test_prestart_is_executable():
    assert APP_DIR.joinpath("prestart.sh").stat().st_mode & 0o111


def test_prestart_hook_behaves():
    """Run the hook against a sandbox with chown stubbed.

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
    prestart = hook_code()

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
    prestart = hook_code()

    calls = re.findall(r"chown\s+((?:-\S+\s+)*)\S+\s+(\S+)", prestart)
    assert calls, "no chown call parsed -- the guard would pass vacuously"
    recursive_targets = [target for flags, target in calls if "R" in flags]
    forbidden = {"CONTAINER_DATA_ROOT", "SIGNALK_DATA"}
    for target in recursive_targets:
        referenced = set(re.findall(r"\$\{?(\w+)", target))
        assert not (referenced & forbidden), (
            f"recursive chown over {target} walks node_modules"
        )


def test_prestart_masks_an_inherited_mode_to_permission_bits():
    """The migration copies settings.json's mode onto the files it creates, and
    uid 1000 owns settings.json -- so the container chooses that mode.

    `stat.S_IMODE` is `mode & 0o7777`, which keeps setuid and setgid. Root then
    reproduces them on settings.json.pre-liner, a file it creates and never hands
    over, so nothing clears them afterwards. Guarded here rather than in
    tools/test-prestart.sh because that harness cannot see it: it refuses to run
    as root, and the kernel strips those bits for any writer without CAP_FSETID.
    """
    prestart = hook_code()

    calls = [line for line in prestart.splitlines() if "stat.S_IMODE(" in line]
    assert calls, "no S_IMODE call parsed -- the guard would pass vacuously"
    for line in calls:
        assert "& 0o777" in line, (
            f"an inherited mode reaches a root create unmasked: {line.strip()}"
        )


def test_prestart_does_not_gate_influxdb_on_the_data_volume():
    """The plugin lives in the image, so the data volume cannot attest to it.

    A presence check under the data volume's node_modules is false on every
    freshly imaged device -- nothing puts the plugin there any more -- and the
    token config is then never written for the whole life of that device.
    Silent: the server starts, and only the graphs are empty.
    """
    prestart = hook_code()

    assert "node_modules/signalk-to-influxdb2" not in prestart
