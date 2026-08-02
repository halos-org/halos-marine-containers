#!/bin/bash
# Seed the curated Signal K plugin/webapp set into the data volume.
#
# Executed by marine-signalk-server-container-provision.service before the app
# starts, so the plugins are on disk when Signal K scans node_modules at server
# startup. Runs on every app start, so it is a presence check first and an
# installer second. See the Provisioning Hook contract in container-packaging-tools.
#
# The plugins are ordinary npm packages, so Signal K's own app store updates them
# individually afterwards with no deb rebuild. Present packages are skipped, which
# is what keeps an app-store-updated plugin from being downgraded.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/assets/plugins.list"
SIGNALK_DATA="${CONTAINER_DATA_ROOT}/data"
NPM_CACHE="${CONTAINER_DATA_ROOT}/npm-cache"

# The container runs as node (uid 1000) and npm writes as that user.
CONTAINER_UID=1000
CONTAINER_GID=1000

# Per-package stop-loss, and a total wall-clock budget for the whole run. The app's
# start job waits on this unit, so the budget bounds how long a boot is delayed;
# whatever does not fit is picked up on the next start.
#
# Measured on a CM5 (the HALPI2 class) over a normal connection: the full 17-package
# set takes ~72s cold, and the slowest single package is @signalk/charts-plugin at
# ~39s. These leave roughly 4x margin on both without letting a pathological run
# hold the app for many minutes.
PACKAGE_TIMEOUT=180
BUDGET=300

[ -f "${MANIFEST}" ] || { echo "no manifest at ${MANIFEST}; nothing to provision"; exit 0; }

SIGNALK_IMAGE="$(grep -oP 'image:\s*\K\S+' "${SCRIPT_DIR}/docker-compose.yml" | head -1)"
[ -n "${SIGNALK_IMAGE}" ] || { echo "WARNING: no image in docker-compose.yml; skipping"; exit 0; }

# A package counts as installed when its package.json names it. Bare directory
# existence marks a power-loss-truncated install as done forever.
is_installed() {
    local pkg="$1" pkg_json="${SIGNALK_DATA}/node_modules/$1/package.json"
    [ -f "${pkg_json}" ] && grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${pkg}\"" "${pkg_json}"
}

read_manifest() {
    # Strips comments and CR (a Windows-edited manifest would otherwise make every
    # entry "name\r"); the || guard keeps a final line that lacks a newline.
    local line pkg
    while IFS= read -r line || [ -n "${line}" ]; do
        pkg="${line%%#*}"
        pkg="${pkg//$'\r'/}"
        pkg="${pkg#"${pkg%%[![:space:]]*}"}"
        pkg="${pkg%"${pkg##*[![:space:]]}"}"
        [ -n "${pkg}" ] && printf '%s\n' "${pkg}"
    done < "${MANIFEST}"
}

mapfile -t WANTED < <(read_manifest)
MISSING=()
for pkg in "${WANTED[@]}"; do
    is_installed "${pkg}" || MISSING+=("${pkg}")
done

# The common case by far: everything is already present, so this must stay cheap.
if [ ${#MISSING[@]} -eq 0 ]; then
    echo "all ${#WANTED[@]} curated packages present"
    exit 0
fi

# Fail fast when there is no route to the registry. Without this, each missing
# package burns its own timeout on DNS before failing, turning an offline boot
# into a multi-minute delay for work that cannot succeed.
if ! timeout 5 getent hosts registry.npmjs.org >/dev/null 2>&1; then
    echo "registry.npmjs.org does not resolve; skipping ${#MISSING[@]} package(s) until the next start"
    exit 0
fi
if ! timeout 10 curl -sfI https://registry.npmjs.org/ >/dev/null 2>&1; then
    echo "registry.npmjs.org resolves but is unreachable; skipping ${#MISSING[@]} package(s) until the next start"
    exit 0
fi

# Nothing upstream guarantees these exist with container-user ownership: postinst
# derives it from the compose service's `user:` field, which this app does not set,
# and the app's prestart (where the blanket chown lives) has not run yet.
mkdir -p "${SIGNALK_DATA}" "${NPM_CACHE}"
chown "${CONTAINER_UID}:${CONTAINER_GID}" "${SIGNALK_DATA}" "${NPM_CACHE}"

# A previous run killed at its start timeout can leave this behind still writing to
# the volume. The unit's ExecStopPost reaps the same name on that path.
docker rm -f "${HALOS_PROVISION_CONTAINER}" >/dev/null 2>&1 || true

echo "provisioning ${#MISSING[@]} of ${#WANTED[@]} curated packages"
started=${SECONDS}
installed=0
deferred=0

for pkg in "${MISSING[@]}"; do
    elapsed=$((SECONDS - started))
    if [ "${elapsed}" -ge "${BUDGET}" ]; then
        deferred=$((deferred + 1))
        continue
    fi

    echo "installing ${pkg}"
    if timeout "${PACKAGE_TIMEOUT}" docker run --rm \
        --name "${HALOS_PROVISION_CONTAINER}" \
        --entrypoint npm \
        -v "${SIGNALK_DATA}:/home/node/.signalk" \
        -v "${NPM_CACHE}:/home/node/.npm" \
        -u "${CONTAINER_UID}:${CONTAINER_GID}" \
        "${SIGNALK_IMAGE}" \
        install --prefix /home/node/.signalk --cache /home/node/.npm "${pkg}"; then
        installed=$((installed + 1))
    else
        # timeout kills the client; the container keeps running without this.
        docker rm -f "${HALOS_PROVISION_CONTAINER}" >/dev/null 2>&1 || true
        echo "WARNING: ${pkg} failed or timed out; retrying on the next start"
    fi
done

if [ "${deferred}" -gt 0 ]; then
    echo "budget of ${BUDGET}s reached; ${deferred} package(s) deferred to the next start"
fi
echo "provisioning done: ${installed} installed, $(( ${#MISSING[@]} - installed )) still missing"

# Always succeed: a missing package is retried next start, and a failed unit would
# only report a degraded system for a condition that is not a fault.
exit 0
