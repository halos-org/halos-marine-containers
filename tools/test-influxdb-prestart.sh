#!/usr/bin/env bash
# Integration test for apps/influxdb/prestart.sh against a real InfluxDB.
#
# The hook manages the admin API token and password of an initialized database,
# so the only meaningful test subject is a real InfluxDB on a real data volume.
# Each scenario builds a data directory in a temporary workspace, runs the hook
# the way ExecStartPre runs it (sourced under `set -e`), and then inspects what
# InfluxDB actually accepts.
#
# Requires: docker, GNU grep, sha256sum. Nothing here touches /etc or a device.
#
# Usage: tools/test-influxdb-prestart.sh

set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${REPO_ROOT}/apps/influxdb/prestart.sh"
IMAGE="$(grep -oP 'image:\s*\K\S+' "${REPO_ROOT}/apps/influxdb/docker-compose.yml" | head -1)"
PLACEHOLDER="halos-default-token-change-in-production"
PROBE_CONTAINER="influxdb-prestart-test"
WORKSPACE="$(mktemp -d)"
PASS=0
FAIL=0

cleanup() {
    docker rm -f "${PROBE_CONTAINER}" influxdb-prestart-helper >/dev/null 2>&1
    rm -rf "${WORKSPACE}"
}
trap cleanup EXIT

log() { echo "    $*"; }

check() { # check <description> <expected> <actual>
    if [ "$2" = "$3" ]; then
        echo "  PASS: $1 ($3)"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $1 -- expected '$2', got '$3'"
        FAIL=$((FAIL + 1))
    fi
}

scenario() {
    echo
    echo "=================================================================="
    echo "$*"
    echo "=================================================================="
}

fresh_install() { # fresh_install <name>
    DATA="${WORKSPACE}/$1/data"
    ETC="${WORKSPACE}/$1/etc"
    rm -rf "${WORKSPACE:?}/$1"
    mkdir -p "${DATA}/config" "${DATA}/db" "${ETC}"
}

start_influx() { # start_influx [-e KEY=VAL ...]
    docker rm -f "${PROBE_CONTAINER}" >/dev/null 2>&1
    docker run -d --name "${PROBE_CONTAINER}" \
        -v "${DATA}/config:/etc/influxdb2" \
        -v "${DATA}/db:/var/lib/influxdb2" \
        "$@" "${IMAGE}" >/dev/null
    for _ in $(seq 1 60); do
        [ "$(status "" health)" = "200" ] && return 0
        sleep 1
    done
    echo "  ERROR: InfluxDB did not become ready"
    return 1
}

stop_influx() { docker rm -f "${PROBE_CONTAINER}" >/dev/null 2>&1; }

status() { # status <token> <path> -> HTTP status
    docker exec "${PROBE_CONTAINER}" curl -s -o /dev/null -w '%{http_code}' \
        -H "Authorization: Token $1" "http://localhost:8086/$2" 2>/dev/null
}

probe() { status "$1" api/v2/me; }

# Initializes a database the way the app's docker-compose.yml does.
initialize_influx() { # initialize_influx <admin token>
    start_influx \
        -e DOCKER_INFLUXDB_INIT_MODE=setup \
        -e DOCKER_INFLUXDB_INIT_USERNAME=admin \
        -e DOCKER_INFLUXDB_INIT_PASSWORD=halos-default \
        -e DOCKER_INFLUXDB_INIT_ORG=marine \
        -e DOCKER_INFLUXDB_INIT_BUCKET=marine \
        -e DOCKER_INFLUXDB_INIT_ADMIN_TOKEN="$1" || return 1
    stop_influx
}

authorization_count() { docker exec "${PROBE_CONTAINER}" influx auth list --json -t "$1" 2>/dev/null | grep -c '"status"'; }

hash_of() { printf '%s' "$1" | sha256sum | cut -d' ' -f1; }

env_token() { grep '^INFLUXDB_ADMIN_TOKEN=' "${ETC}/env" | cut -d= -f2-; }

set_env_token() { printf 'INFLUXDB_ADMIN_TOKEN=%s\n' "$1" > "${ETC}/env"; }

helper_containers() { docker ps -a --filter name=influxdb-prestart-helper --format '{{.Names}}'; }

# The framework prestart exports the env files and sources the hook under set -e.
run_hook() { # run_hook [KEY=VALUE ...]
    HOOK_OUTPUT=$(env CONTAINER_DATA_ROOT="${DATA}" ETC_DIR="${ETC}" "$@" \
        bash -c 'set -e; . "$1"' _ "${HOOK}" 2>&1)
    HOOK_STATUS=$?
    log "exit=${HOOK_STATUS}"
    echo "${HOOK_OUTPUT}" | sed 's/^/    | /'
}

if [ -z "${IMAGE}" ]; then
    echo "Could not read the InfluxDB image from apps/influxdb/docker-compose.yml"
    exit 1
fi
echo "Testing ${HOOK}"
echo "Image: ${IMAGE}"

scenario "1. Repair: InfluxDB rejects the token in the env file"
fresh_install repair
initialize_influx "${PLACEHOLDER}" || exit 1
STALE="stale-token-that-influxdb-never-saw"
set_env_token "${STALE}"
run_hook INFLUXDB_ADMIN_TOKEN="${STALE}"
check "hook exits 0" "0" "${HOOK_STATUS}"
REPAIRED=$(env_token)
check "env token replaced" "changed" "$([ "${REPAIRED}" != "${STALE}" ] && echo changed || echo same)"
start_influx || exit 1
check "repaired token authenticates" "200" "$(probe "${REPAIRED}")"
check "default token revoked" "401" "$(probe "${PLACEHOLDER}")"
check "no leftover authorization" "1" "$(authorization_count "${REPAIRED}")"
stop_influx
log "the next boot must trust the recorded token instead of probing again"
run_hook INFLUXDB_ADMIN_TOKEN="${REPAIRED}"
check "hook exits 0" "0" "${HOOK_STATUS}"
check "no temporary InfluxDB started" "" "$(helper_containers)"
check "env token left alone" "${REPAIRED}" "$(env_token)"

scenario "2. Repair: initialized database still answering to the default token"
fresh_install default_token
initialize_influx "${PLACEHOLDER}" || exit 1
set_env_token "${PLACEHOLDER}"
run_hook INFLUXDB_ADMIN_TOKEN="${PLACEHOLDER}"
check "hook exits 0" "0" "${HOOK_STATUS}"
REPAIRED=$(env_token)
check "env token no longer the default" "changed" "$([ "${REPAIRED}" != "${PLACEHOLDER}" ] && echo changed || echo same)"
start_influx || exit 1
check "repaired token authenticates" "200" "$(probe "${REPAIRED}")"
check "default token revoked" "401" "$(probe "${PLACEHOLDER}")"
stop_influx

scenario "3. Prevention: a healthy install is never rotated"
fresh_install healthy
WORKING="a1b2c3d4e5f6a7b8c9d0e1f2a3b4c5d6e7f8a9b0c1d2e3f4a5b6c7d8e9f0a1b2"
initialize_influx "${WORKING}" || exit 1
set_env_token "${WORKING}"
run_hook INFLUXDB_ADMIN_TOKEN="${WORKING}"
check "hook exits 0" "0" "${HOOK_STATUS}"
check "env token untouched" "${WORKING}" "$(env_token)"
start_influx || exit 1
check "token still authenticates" "200" "$(probe "${WORKING}")"
check "no authorization minted" "1" "$(authorization_count "${WORKING}")"
stop_influx

scenario "4. Revocation leaves user-created tokens alone"
fresh_install user_token
initialize_influx "${PLACEHOLDER}" || exit 1
start_influx || exit 1
USER_TOKEN=$(docker exec "${PROBE_CONTAINER}" influx auth create --all-access --org marine --json \
    -t "${PLACEHOLDER}" | awk -F'"' '$2=="token"{print $4; exit}')
check "user token works before the repair" "200" "$(probe "${USER_TOKEN}")"
stop_influx
set_env_token "${STALE}"
run_hook INFLUXDB_ADMIN_TOKEN="${STALE}"
check "hook exits 0" "0" "${HOOK_STATUS}"
REPAIRED=$(env_token)
start_influx || exit 1
check "repaired token authenticates" "200" "$(probe "${REPAIRED}")"
check "default token revoked" "401" "$(probe "${PLACEHOLDER}")"
check "user token still active" "200" "$(probe "${USER_TOKEN}")"
check "user token and repaired token remain" "2" "$(authorization_count "${REPAIRED}")"
stop_influx

scenario "5. A failed password sync must not fail ExecStartPre"
fresh_install password_sync
initialize_influx "${WORKING}" || exit 1
set_env_token "${WORKING}"
hash_of halos-default > "${DATA}/.password-shadow"
run_hook INFLUXDB_ADMIN_TOKEN="${WORKING}" INFLUXDB_ADMIN_USER=boatadmin \
    INFLUXDB_ADMIN_PASSWORD=newpassword123
check "hook exits 0" "0" "${HOOK_STATUS}"
check "failure is reported" "yes" "$(echo "${HOOK_OUTPUT}" | grep -q "could not update the password" && echo yes || echo no)"
check "shadow not advanced, so the next boot retries" "$(hash_of halos-default)" "$(cat "${DATA}/.password-shadow")"
log "a password change for the real user still syncs"
run_hook INFLUXDB_ADMIN_TOKEN="${WORKING}" INFLUXDB_ADMIN_PASSWORD=newpassword123
check "hook exits 0" "0" "${HOOK_STATUS}"
start_influx || exit 1
check "InfluxDB accepts the new password" "204" \
    "$(docker exec "${PROBE_CONTAINER}" curl -s -o /dev/null -w '%{http_code}' \
        -X POST -u "admin:newpassword123" http://localhost:8086/api/v2/signin 2>/dev/null)"
stop_influx

scenario "6. Fresh install: token generated before the first setup"
fresh_install first_boot
set_env_token "${PLACEHOLDER}"
run_hook INFLUXDB_ADMIN_TOKEN="${PLACEHOLDER}"
check "hook exits 0" "0" "${HOOK_STATUS}"
GENERATED=$(env_token)
check "generated a random token" "64" "${#GENERATED}"
check "no temporary InfluxDB started" "" "$(helper_containers)"
initialize_influx "${GENERATED}" || exit 1
start_influx || exit 1
check "InfluxDB initialized with the generated token" "200" "$(probe "${GENERATED}")"
stop_influx

scenario "7. Unreachable database: the hook stays out of the way"
fresh_install unreachable
printf 'not a bolt file' > "${DATA}/db/influxd.bolt"
set_env_token "${STALE}"
run_hook INFLUXDB_ADMIN_TOKEN="${STALE}"
check "hook exits 0" "0" "${HOOK_STATUS}"
check "env token untouched" "${STALE}" "$(env_token)"
check "temporary InfluxDB cleaned up" "" "$(helper_containers)"

echo
echo "=================================================================="
echo "PASS=${PASS} FAIL=${FAIL}"
echo "=================================================================="
[ "${FAIL}" -eq 0 ]
