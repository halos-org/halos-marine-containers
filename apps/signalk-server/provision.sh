#!/bin/bash
# Install the curated Signal K plugin/webapp set into the data volume.
#
# Executed by marine-signalk-server-container-provision.service, which the app
# Requires=, so Signal K does not start until this exits 0. The plugins are part
# of the product; a server running without them is a degraded install, not a
# working one. See the Provisioning Hook contract in container-packaging-tools.
#
# That requirement belongs to the package transaction: an install or an upgrade
# must provision completely, and every other boot exits immediately. Nothing
# outside this script retries it, so it retries internally -- transient
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
# without an uplink is not spinning. No overall deadline: only a gated run gets
# this far, and giving up on a transient fault would strand the upgrade.
RETRY_MIN=10
RETRY_MAX=300

# Provisioning is a hard requirement of the package transaction, not of every
# boot. A fresh install or an upgrade must complete before Signal K starts; an
# ordinary boot must not put the navigation server behind the npm registry. The
# installed package version is the transaction marker, so any new .deb -- one
# that only edits the manifest included -- re-arms the gate.
PACKAGE_NAME="$(basename "$(dirname "${CONTAINER_DATA_ROOT}")")"
PROVISIONED_MARKER="${CONTAINER_DATA_ROOT}/.provisioned"

installed_version() { dpkg-query -W -f='${Version}' "${PACKAGE_NAME}" 2>/dev/null; }

# 0 = this run must finish before the app may start.
gate_armed() {
    local installed marker
    installed="$(installed_version)"
    # Unable to tell which version is installed: hold the gate rather than let a
    # half-provisioned upgrade through.
    [ -n "${installed}" ] || return 0
    # No marker reads as an empty version, which never matches.
    marker="$(cat "${PROVISIONED_MARKER}" 2>/dev/null)"
    [ "${marker}" = "${installed}" ] && return 1 || return 0
}

mark_provisioned() {
    local installed
    installed="$(installed_version)"
    [ -n "${installed}" ] && printf '%s\n' "${installed}" > "${PROVISIONED_MARKER}"
    return 0
}


log() { echo "provision: $*"; }

[ -f "${MANIFEST}" ] || { log "no manifest at ${MANIFEST}; nothing to do"; exit 0; }

# Nothing to do on an ordinary boot: this package version already provisioned
# successfully, so the app starts without touching docker or the registry. A
# plugin the operator has since removed through the app store stays removed
# until the next .deb re-arms the gate.
if ! gate_armed; then
    log "already provisioned for $(installed_version); nothing to do"
    exit 0
fi

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

# npm writes as uid 1000, but nothing upstream guarantees it can: the app declares
# no compose `user:`, and the pi-gen SK-plugin stages and signalk-halpi's postinst
# create node_modules root-owned (halos-org/halos-pi-gen-template#5), which fails
# EACCES for every package forever on an imaged device.
# -h because these sit in a directory the container writes: following a symlink
# would let it choose which host path root hands over.
prepare_paths() {
    mkdir -p "${SIGNALK_DATA}/node_modules" "${NPM_CACHE}"
    chown -h "${CONTAINER_UID}:${CONTAINER_GID}" \
        "${SIGNALK_DATA}" "${SIGNALK_DATA}/node_modules" "${NPM_CACHE}"
    [ -f "${NPM_MANIFEST}" ] &&
        chown -h "${CONTAINER_UID}:${CONTAINER_GID}" "${NPM_MANIFEST}"
    return 0
}

# No deployed device has the -core image cached, so every upgrade pulls. Left to
# the app's ExecStart, five failures inside StartLimitIntervalSec leave a unit
# that does not self-heal.
ensure_image() {
    local out status
    docker image inspect "${SIGNALK_IMAGE}" >/dev/null 2>&1 && return 0

    log "pulling ${SIGNALK_IMAGE}"
    out="$(timeout -k 10 "${IMAGE_PULL_TIMEOUT}" docker pull "${SIGNALK_IMAGE}" 2>&1)"
    status=$?
    [ "${status}" -eq 0 ] && return 0

    if grep -qE 'manifest unknown|manifest for .* not found' <<<"${out}"; then
        log "ERROR: ${SIGNALK_IMAGE} does not exist in the registry"
        return 2
    fi
    log "pulling ${SIGNALK_IMAGE} failed (exit ${status}); will retry"
    return 1
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
        install --ignore-scripts --prefix /home/node/.signalk --cache /home/node/.npm "${pkg}" 2>&1)"
    status=$?
    [ "${status}" -eq 0 ] && return 0

    # The client can be killed while the container keeps writing to the volume.
    docker rm -f "${HALOS_PROVISION_CONTAINER}" >/dev/null 2>&1 || true

    if grep -qE 'E404|404 Not Found|is not in the npm registry' <<<"${out}"; then
        log "ERROR: ${pkg} does not exist in the registry"
        return 2
    fi
    log "${pkg} failed (exit ${status}): $(tail -3 <<<"${out}" | tr '\n' ' ')"
    return 1
}

# Plain sed, not `grep -oP`: PCRE is a GNU extension, and on any other grep the
# match silently yields nothing rather than failing.
SIGNALK_IMAGE="$(sed -n 's/^[[:space:]]*image:[[:space:]]*\([^[:space:]]*\).*/\1/p' \
    "${SCRIPT_DIR}/docker-compose.yml" | head -1)"
[ -n "${SIGNALK_IMAGE}" ] || { log "ERROR: no image in docker-compose.yml"; exit 1; }

# A container the last run left behind keeps writing to the data volume.
# ExecStopPost reaps it on an ordinary stop; this covers a hard kill.
docker rm -f "${HALOS_PROVISION_CONTAINER}" >/dev/null 2>&1 || true

mapfile -t WANTED < <(read_manifest)
[ ${#WANTED[@]} -gt 0 ] || { log "manifest is empty; nothing to do"; exit 0; }

# The image is needed whatever the manifest says, and once pulled it stays
# pulled -- so it is settled here rather than re-checked on every pass.
delay=${RETRY_MIN}
while true; do
    ensure_image
    case $? in
        0) break ;;
        2) log "ERROR: giving up. Signal K cannot start without its image."; exit 1 ;;
    esac
    log "image unavailable; retrying in ${delay}s"
    sleep "${delay}"
    delay=$(( delay * 2 > RETRY_MAX ? RETRY_MAX : delay * 2 ))
done

delay=${RETRY_MIN}
attempt=0
previously_missing=-1

while true; do
    attempt=$((attempt + 1))

    missing=()
    for pkg in "${WANTED[@]}"; do
        is_installed "${pkg}" || missing+=("${pkg}")
    done

    if [ ${#missing[@]} -eq 0 ]; then
        [ "${attempt}" -eq 1 ] &&
            log "all ${#WANTED[@]} curated packages present" ||
            log "provisioning complete after ${attempt} attempts"
        mark_provisioned
        exit 0
    fi

    # Progress is the outstanding count shrinking, not npm's exit status: a
    # package that installs cleanly without satisfying is_installed would
    # otherwise reset the backoff forever and spin with no sleep at all.
    if [ "${previously_missing}" -ge 0 ] && [ ${#missing[@]} -ge "${previously_missing}" ]; then
        log "no package installed last attempt; retrying in ${delay}s"
        sleep "${delay}"
        delay=$(( delay * 2 > RETRY_MAX ? RETRY_MAX : delay * 2 ))
    else
        delay=${RETRY_MIN}
    fi
    previously_missing=${#missing[@]}

    prepare_paths

    log "attempt ${attempt}: installing ${#missing[@]} of ${#WANTED[@]} curated packages"
    for pkg in "${missing[@]}"; do
        log "installing ${pkg}"
        install_package "${pkg}"
        if [ $? -eq 2 ]; then
            log "ERROR: giving up. ${pkg} cannot be installed by waiting, so"
            log "ERROR: Signal K will not start until the manifest is corrected."
            exit 1
        fi
    done
done
