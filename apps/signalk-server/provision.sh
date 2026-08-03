#!/bin/bash
# Install the curated Signal K plugin/webapp set into the data volume.
#
# Executed by marine-signalk-server-container-provision.service, which the app
# Requires=, so Signal K does not start until this exits 0. The plugins are part
# of the product; a server running without them is a degraded install, not a
# working one. See the Provisioning Hook contract in container-packaging-tools.
#
# Nothing outside this script retries it, so it retries internally: transient
# conditions sleep and try again, and only a failure that waiting cannot fix
# exits non-zero. The plugins are ordinary npm packages, so Signal K's app store
# updates them individually afterwards; anything already present is left alone,
# which is what keeps an app-store-updated plugin from being downgraded.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="${SCRIPT_DIR}/assets/plugins.list"
SIGNALK_DATA="${CONTAINER_DATA_ROOT}/data"
NPM_CACHE="${CONTAINER_DATA_ROOT}/npm-cache"
NPM_MANIFEST="${SIGNALK_DATA}/package.json"

# The container runs as node, and npm writes the tree as that user.
CONTAINER_UID=1000
CONTAINER_GID=1000

# Set by the provisioning unit. Defaulted so running this by hand does not abort
# under `set -u` after the directory work has already happened.
HALOS_PROVISION_CONTAINER="${HALOS_PROVISION_CONTAINER:-marine-signalk-server-container-provision}"

# Per-package stop-loss. Measured on a CM5 (the HALPI2 class): the full set takes
# ~72s cold and the slowest single package is @signalk/charts-plugin at ~39s.
PACKAGE_TIMEOUT=180

# The image is ~400 MB and an upgrade pulls it whole. Generous because a killed
# pull is not wasted -- completed layers stay cached, so each retry resumes.
IMAGE_PULL_TIMEOUT=1800

# Retry backoff for conditions that can resolve by waiting, capped so a boat
# without an uplink is not spinning. There is no overall deadline: the app is
# gated on this hook, so giving up on a transient fault would strand it.
RETRY_MIN=10
RETRY_MAX=300

log() { echo "provision: $*"; }

[ -f "${MANIFEST}" ] || { log "no manifest at ${MANIFEST}; nothing to do"; exit 0; }

# Strips comments and CR (a Windows-edited manifest would otherwise make every
# entry "name\r"); the || guard keeps a final line that lacks a newline.
read_manifest() {
    local line pkg
    while IFS= read -r line || [ -n "${line}" ]; do
        pkg="${line%%#*}"
        pkg="${pkg//$'\r'/}"
        pkg="${pkg#"${pkg%%[![:space:]]*}"}"
        pkg="${pkg%"${pkg##*[![:space:]]}"}"
        [ -n "${pkg}" ] && printf '%s\n' "${pkg}"
    done < "${MANIFEST}"
}

# Two conditions, because either alone is satisfiable by a broken tree. npm
# extracts a package's own package.json first, so a reify killed mid-extraction
# leaves that file matching over an incomplete directory; and npm records the
# dependency in the prefix's package.json only once the install completes.
is_installed() {
    local pkg="$1" pkg_json="${SIGNALK_DATA}/node_modules/$1/package.json"
    [ -f "${pkg_json}" ] || return 1
    grep -q "\"name\"[[:space:]]*:[[:space:]]*\"${pkg}\"" "${pkg_json}" || return 1
    [ -f "${NPM_MANIFEST}" ] || return 1
    grep -q "\"${pkg}\"[[:space:]]*:" "${NPM_MANIFEST}"
}

# Hand over every path npm needs to write. Nothing upstream guarantees this: the
# app declares no compose `user:`, so postinst creates the data root as root, and
# the pi-gen SK-plugin stages and signalk-halpi's postinst both create
# node_modules root-owned (halos-org/halos-pi-gen-template#5). npm then fails
# EACCES for every package, forever, on an imaged device.
# -h on every call: node_modules and package.json sit in a directory the container
# writes, so a symlink planted there would otherwise pick which host path root
# hands to uid 1000. The recursive chown this replaced was safe by accident --
# chown -R defaults to -P and does not follow symlinks.
prepare_paths() {
    mkdir -p "${SIGNALK_DATA}/node_modules" "${NPM_CACHE}"
    chown -h "${CONTAINER_UID}:${CONTAINER_GID}" \
        "${SIGNALK_DATA}" "${SIGNALK_DATA}/node_modules" "${NPM_CACHE}"
    [ -f "${NPM_MANIFEST}" ] &&
        chown -h "${CONTAINER_UID}:${CONTAINER_GID}" "${NPM_MANIFEST}"
    return 0
}

# The app unit is gated on this hook, so the image it needs is this hook's job to
# have. Without it the pull lands in the app's ExecStart instead, where five
# failures inside StartLimitIntervalSec leave a unit that does not self-heal --
# and no deployed device has the -core image cached, so every upgrade takes that
# path. Same three-way result as install_package.
ensure_image() {
    local out status
    docker image inspect "${SIGNALK_IMAGE}" >/dev/null 2>&1 && return 0

    log "pulling ${SIGNALK_IMAGE}"
    out="$(timeout -k 10 "${IMAGE_PULL_TIMEOUT}" docker pull "${SIGNALK_IMAGE}" 2>&1)"
    status=$?
    [ "${status}" -eq 0 ] && return 0

    if grep -qE 'manifest unknown|manifest for .* not found|repository does not exist' <<<"${out}"; then
        log "ERROR: ${SIGNALK_IMAGE} does not exist in the registry"
        return 2
    fi
    log "pulling ${SIGNALK_IMAGE} failed (exit ${status}); will retry"
    return 1
}

registry_reachable() {
    if ! command -v curl >/dev/null 2>&1; then
        # Cannot probe, so do not claim to know. Let the install attempt report.
        return 0
    fi
    timeout 5 getent hosts registry.npmjs.org >/dev/null 2>&1 || return 1
    timeout 10 curl -sfI https://registry.npmjs.org/ >/dev/null 2>&1
}

# Returns 0 installed, 1 transient failure, 2 the registry says it will never
# exist. Only the last is worth giving up over.
install_package() {
    local pkg="$1" out status
    docker rm -f "${HALOS_PROVISION_CONTAINER}" >/dev/null 2>&1 || true
    out="$(timeout -k 10 "${PACKAGE_TIMEOUT}" docker run --rm \
        --name "${HALOS_PROVISION_CONTAINER}" \
        --entrypoint npm \
        -v "${SIGNALK_DATA}:/home/node/.signalk" \
        -v "${NPM_CACHE}:/home/node/.npm" \
        -u "${CONTAINER_UID}:${CONTAINER_GID}" \
        "${SIGNALK_IMAGE}" \
        install --prefix /home/node/.signalk --cache /home/node/.npm "${pkg}" 2>&1)"
    status=$?
    [ "${status}" -eq 0 ] && return 0

    # The client can be killed while the container keeps writing to the volume.
    docker rm -f "${HALOS_PROVISION_CONTAINER}" >/dev/null 2>&1 || true

    if grep -qE 'E404|404 Not Found|is not in the npm registry' <<<"${out}"; then
        log "ERROR: ${pkg} does not exist in the registry"
        return 2
    fi
    log "${pkg} failed (exit ${status}); will retry"
    return 1
}

# Plain sed, not `grep -oP`: PCRE is a GNU extension, and on any other grep the
# match silently yields nothing rather than failing.
SIGNALK_IMAGE="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    "${SCRIPT_DIR}/docker-compose.yml" | head -1)"
[ -n "${SIGNALK_IMAGE}" ] || { log "ERROR: no image in docker-compose.yml"; exit 1; }

mapfile -t WANTED < <(read_manifest)
[ ${#WANTED[@]} -gt 0 ] || { log "manifest is empty; nothing to do"; exit 0; }

delay=${RETRY_MIN}
attempt=0

while true; do
    attempt=$((attempt + 1))

    # Ahead of the all-present short-circuit: an upgraded device has every
    # package already and still needs the image.
    ensure_image
    case $? in
        1)
            log "image unavailable; retrying in ${delay}s"
            sleep "${delay}"
            delay=$(( delay * 2 > RETRY_MAX ? RETRY_MAX : delay * 2 ))
            continue
            ;;
        2)
            log "ERROR: giving up. Signal K cannot start without its image."
            exit 1
            ;;
    esac

    missing=()
    for pkg in "${WANTED[@]}"; do
        is_installed "${pkg}" || missing+=("${pkg}")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        [ "${attempt}" -eq 1 ] &&
            log "all ${#WANTED[@]} curated packages present" ||
            log "provisioning complete after ${attempt} attempts"
        exit 0
    fi

    prepare_paths

    if ! registry_reachable; then
        log "registry unreachable; retrying in ${delay}s (${#missing[@]} package(s) outstanding)"
        sleep "${delay}"
        delay=$(( delay * 2 > RETRY_MAX ? RETRY_MAX : delay * 2 ))
        continue
    fi

    log "attempt ${attempt}: installing ${#missing[@]} of ${#WANTED[@]} curated packages"
    progressed=0
    for pkg in "${missing[@]}"; do
        log "installing ${pkg}"
        install_package "${pkg}"
        case $? in
            0) progressed=1 ;;
            2)
                log "ERROR: giving up. ${pkg} cannot be installed by waiting, so"
                log "ERROR: Signal K will not start until the manifest is corrected."
                exit 1
                ;;
        esac
    done

    # Reset the backoff whenever something landed, so a slow link that installs
    # one package per pass is not punished for making progress.
    if [ "${progressed}" -eq 1 ]; then
        delay=${RETRY_MIN}
    else
        log "no package installed this attempt; retrying in ${delay}s"
        sleep "${delay}"
        delay=$(( delay * 2 > RETRY_MAX ? RETRY_MAX : delay * 2 ))
    fi
done
