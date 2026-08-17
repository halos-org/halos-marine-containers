"""Tests for the Grafana app's datasource provisioning.

Grafana only recommends the two datastores, so which datasources exist is
decided at every start by what is installed. The failure mode when that goes
wrong is quiet: Grafana starts, the dashboard list is intact, and only a panel
query says anything -- so the checks that matter are about which file the hook
looks at and what it copies, neither of which any device symptom points to.
"""

import subprocess
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).parent.parent
APP_DIR = REPO_ROOT / "apps" / "grafana"
ASSETS_DIR = APP_DIR / "assets"


def _yaml(path: Path) -> dict:
    with open(path) as f:
        return yaml.safe_load(f)


def hook_code() -> str:
    """The hook's text, minus comment lines.

    The guards below are substring checks, and this repo's house style puts the
    reasoning directly above the code it justifies -- so matching the whole file
    would fire on prose and discourage writing it.
    """
    lines = (APP_DIR / "prestart.sh").read_text().splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("#"))


def test_prestart_is_executable():
    assert APP_DIR.joinpath("prestart.sh").stat().st_mode & 0o111


def test_prestart_hook_behaves():
    """Run the hook against sandboxed install states with chown stubbed.

    Which datasources exist afterwards is a property of the filesystem, which no
    assertion on the script's text reaches.
    """
    harness = REPO_ROOT / "tools" / "test-grafana-prestart.sh"

    result = subprocess.run(
        ["bash", str(harness)], capture_output=True, text=True, timeout=120
    )

    assert result.returncode == 0, result.stdout + result.stderr


def test_installed_means_the_compose_file():
    """`apt remove` is not `apt purge`, and only one of them takes the env file.

    A removed package lands in `deinstall ok config-files`, where
    /etc/container-apps/<app>/env and the systemd unit both survive; the compose
    file is payload and goes on either. Gating on the env file made "the app is
    gone" false for the ordinary uninstall, so Grafana kept a datasource
    pointing at a container that can no longer start.
    """
    code = hook_code()

    for app in ("influxdb", "questdb"):
        gate = f'[ -f "${{{app.upper()}_COMPOSE}}" ]'
        assert gate in code, f"{app} is not gated on its compose file"

    # The InfluxDB env file is still read -- it holds the token -- so the guard
    # above is not enough on its own: it would pass with an `||` in place of the
    # `&&` that makes the compose file necessary rather than sufficient.
    assert '[ -f "${INFLUXDB_COMPOSE}" ] && [ -f "${INFLUXDB_ENV}" ]' in code


def test_questdb_datasource_reaches_the_port_the_app_publishes():
    """The datasource hard-codes host and port; the app decides both.

    Grafana reaches QuestDB over halos-proxy-network, so the container port is
    what it connects to and the loopback publication in the compose file is not
    involved. A repin that moves the PostgreSQL wire port would leave this
    datasource pointing at a closed port, and nothing else in either repo
    compares the two.
    """
    datasource = _yaml(ASSETS_DIR / "questdb-datasource.yaml")["datasources"][0]
    assert datasource["type"] == "postgres"

    host, _, port = datasource["url"].partition(":")

    compose = _yaml(REPO_ROOT / "apps" / "questdb" / "docker-compose.yml")
    service_name, service = next(iter(compose["services"].items()))
    assert host == service.get("container_name", service_name)

    container_ports = {mapping.rsplit(":", 1)[-1] for mapping in service["ports"]}
    assert port in container_ports, (
        f"the datasource dials {port}, which apps/questdb publishes no service on"
    )


def test_grafana_recommends_every_datastore_it_provisions():
    """Recommends is what puts the app in front of someone installing Grafana.

    A datasource whose app is not recommended is provisioned for a database that
    nothing suggested installing, so the default experience is a dashboard with
    nothing to query.
    """
    recommends = set(_yaml(APP_DIR / "metadata.yaml")["recommends"])

    provisioned = {
        _yaml(asset)["datasources"][0]["name"].lower()
        for asset in ASSETS_DIR.glob("*-datasource.yaml")
    }
    assert provisioned, "no datasource assets found -- the check would pass vacuously"

    for name in provisioned:
        assert f"marine-{name}-container" in recommends
