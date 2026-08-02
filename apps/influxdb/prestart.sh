#!/bin/bash
# InfluxDB app-prestart hook (sourced by the generated framework prestart).
# Runtime dir, env sourcing, and HOMARR_URL are provided by the framework;
# this hook keeps the admin API token usable and syncs the admin password.
#
# The framework prestart runs as ExecStartPre under `set -e`, so a non-zero
# status here keeps the container down and, after a few restarts, latches the
# unit in `failed`. Nothing this hook manages is worth that, so errexit is off
# for the hook and every recoverable problem warns and carries on.
set +e

PACKAGE_NAME="marine-influxdb-container"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="${ETC_DIR:-/etc/container-apps/${PACKAGE_NAME}}"
ENV_FILE="${ETC_DIR}/env"

PLACEHOLDER_TOKEN="halos-default-token-change-in-production"
HELPER_CONTAINER="influxdb-prestart-helper"
LEGACY_HELPER_CONTAINER="influxdb-password-sync"
API_URL="http://localhost:8086"

HELPER_READY=0
OPERATOR_TOKEN=""
SUSPENDED_AUTH_ID=""

influxdb_warn() {
    echo "WARNING: $*" >&2
}

influxdb_hash() {
    printf '%s' "$1" | sha256sum | cut -d' ' -f1
}

influxdb_write_private_file() {
    local file="$1" content="$2" tmp
    tmp=$(mktemp "${file}.XXXXXX") || return 1
    if printf '%s\n' "${content}" > "${tmp}" && chmod 600 "${tmp}" && mv "${tmp}" "${file}"; then
        return 0
    fi
    rm -f "${tmp}"
    return 1
}

# Replaces INFLUXDB_ADMIN_TOKEN in the env file and in this shell, so later
# steps and the container about to start both see the new value.
influxdb_set_admin_token() {
    local token="$1" tmp
    mkdir -p "${ETC_DIR}" || return 1
    tmp=$(mktemp "${ENV_FILE}.XXXXXX") || return 1
    if [ -f "${ENV_FILE}" ]; then
        grep -v '^INFLUXDB_ADMIN_TOKEN=' "${ENV_FILE}" > "${tmp}"
    fi
    if ! { printf 'INFLUXDB_ADMIN_TOKEN=%s\n' "${token}" >> "${tmp}" &&
        chmod 600 "${tmp}" && mv "${tmp}" "${ENV_FILE}"; }; then
        rm -f "${tmp}"
        return 1
    fi
    INFLUXDB_ADMIN_TOKEN="${token}"
    ADMIN_TOKEN="${token}"
}

# --- Temporary InfluxDB ------------------------------------------------------
# Both token repair and password sync have to talk to InfluxDB, but prestart
# runs before the app container, so they share a throwaway one on the same
# volumes. Nothing else can reach it: it publishes no ports.

influxdb_helper_remove() {
    docker rm -f "${HELPER_CONTAINER}" >/dev/null 2>&1
    # Name used before the helper was shared with the token repair.
    docker rm -f "${LEGACY_HELPER_CONTAINER}" >/dev/null 2>&1
    HELPER_READY=0
    return 0
}

influxdb_helper_start() {
    [ "${HELPER_READY}" = "1" ] && return 0

    local image
    image=$(grep -oP 'image:\s*\K\S+' "${SCRIPT_DIR}/docker-compose.yml" | head -1)
    if [ -z "${image}" ]; then
        influxdb_warn "could not read the InfluxDB image from docker-compose.yml"
        return 1
    fi

    # A previous run killed between start and cleanup still holds the data lock.
    trap influxdb_cleanup EXIT
    influxdb_helper_remove

    if ! docker run -d --name "${HELPER_CONTAINER}" \
        -v "${DATA_DIR}/config:/etc/influxdb2" \
        -v "${DATA_DIR}/db:/var/lib/influxdb2" \
        "${image}" >/dev/null 2>&1; then
        influxdb_warn "could not start a temporary InfluxDB container"
        return 1
    fi

    for _ in $(seq 1 30); do
        if [ "$(influxdb_api GET health)" = "200" ]; then
            HELPER_READY=1
            return 0
        fi
        sleep 1
    done

    influxdb_warn "the temporary InfluxDB container did not become ready"
    influxdb_helper_remove
    return 1
}

# Echoes the HTTP status of an API call, or 000 when the call could not be made.
influxdb_api() {
    local method="$1" path="$2" token="${3:-}" body="${4:-}" status
    local args=(-s -o /dev/null -w '%{http_code}' -X "${method}"
        -H "Authorization: Token ${token}")
    if [ -n "${body}" ]; then
        args+=(-H "Content-Type: application/json" -d "${body}")
    fi
    status=$(docker exec "${HELPER_CONTAINER}" curl "${args[@]}" "${API_URL}/${path}" 2>/dev/null)
    printf '%s' "${status:-000}"
}

influxdb_token_is_accepted() {
    case "$(influxdb_api GET api/v2/me "$1")" in
        2*) return 0 ;;
    esac
    return 1
}

influxdb_activate_auth() {
    case "$(influxdb_api PATCH "api/v2/authorizations/$1" "${OPERATOR_TOKEN}" '{"status":"active"}')" in
        2*) return 0 ;;
    esac
    influxdb_warn "authorization $1 was disabled while looking for the default admin token and could not be re-enabled; re-enable it in the InfluxDB UI under Load Data / API Tokens"
    return 1
}

influxdb_cleanup() {
    if [ -n "${SUSPENDED_AUTH_ID}" ]; then
        influxdb_activate_auth "${SUSPENDED_AUTH_ID}"
        SUSPENDED_AUTH_ID=""
    fi
    influxdb_helper_remove
}

# --- Token repair ------------------------------------------------------------
# An admin token can only be minted before InfluxDB initializes, when the
# container is about to consume it, or through InfluxDB itself. Anything else
# desynchronizes the env file from the database.

influxdb_active_auth_ids() {
    docker exec "${HELPER_CONTAINER}" influx auth list --json -t "$1" 2>/dev/null |
        awk -F'"' '$2=="id"{id=$4} $2=="status" && $4=="active" && id!=""{print id; id=""}'
}

# The shipped default token is public knowledge, so an install that still
# answers to it is compromised even once a working token is back in place.
# InfluxDB never reveals token values, so the authorization holding the default
# is identified by disabling candidates until the default stops authenticating.
influxdb_revoke_default_token() {
    local keep_id="$1" id probe

    for id in $(influxdb_active_auth_ids "${OPERATOR_TOKEN}"); do
        [ "${id}" = "${keep_id}" ] && continue

        case "$(influxdb_api PATCH "api/v2/authorizations/${id}" "${OPERATOR_TOKEN}" '{"status":"inactive"}')" in
            2*) SUSPENDED_AUTH_ID="${id}" ;;
            *) continue ;;
        esac

        # Only a 401 proves this authorization is the one holding the default
        # token. A 5xx or an unreachable API says nothing, and deleting on that
        # would destroy a credential InfluxDB cannot reissue.
        #
        # The restore below stays unused in practice: token values are
        # server-generated, so only the setup authorization can hold the default
        # one, and being the oldest it comes up first. The sweep restores anyway
        # rather than depend on that listing order.
        probe=$(influxdb_api GET api/v2/me "${PLACEHOLDER_TOKEN}")
        if [ "${probe}" != "401" ]; then
            # A failed restore keeps the id for the EXIT trap to retry.
            influxdb_activate_auth "${id}" || return 1
            SUSPENDED_AUTH_ID=""
            case "${probe}" in
                2*) continue ;;
            esac
            influxdb_warn "could not tell whether authorization ${id} holds the default admin token (HTTP ${probe}); nothing was deleted. If the default token still works, delete its authorization in the InfluxDB UI under Load Data / API Tokens"
            return 1
        fi

        # Reaching here proves this authorization holds the default token, so
        # the EXIT trap must never put it back, delete or no delete.
        SUSPENDED_AUTH_ID=""
        case "$(influxdb_api DELETE "api/v2/authorizations/${id}" "${OPERATOR_TOKEN}")" in
            2*) echo "Revoked the default admin token (authorization ${id})" ;;
            *) influxdb_warn "the default admin token is disabled but authorization ${id} could not be deleted; remove it in the InfluxDB UI under Load Data / API Tokens" ;;
        esac
        return 0
    done

    influxdb_warn "the default admin token still grants admin access and its authorization could not be identified; delete it in the InfluxDB UI under Load Data / API Tokens"
    return 1
}

influxdb_repair_token() {
    local token_hash auth_id new_token

    token_hash=$(influxdb_hash "${ADMIN_TOKEN}")
    if [ "${ADMIN_TOKEN}" != "${PLACEHOLDER_TOKEN}" ] && [ -n "${ADMIN_TOKEN}" ]; then
        # Checking costs a throwaway InfluxDB, so a token already seen to work
        # is taken on trust until its value changes.
        [ "$(cat "${TOKEN_SHADOW_FILE}" 2>/dev/null)" = "${token_hash}" ] && return 0
    fi

    if ! influxdb_helper_start; then
        influxdb_warn "could not check the admin API token; leaving ${ENV_FILE} untouched"
        return 1
    fi

    if [ "${ADMIN_TOKEN}" = "${PLACEHOLDER_TOKEN}" ] || [ -z "${ADMIN_TOKEN}" ]; then
        echo "InfluxDB is initialized but ${ENV_FILE} still carries the default admin token"
    else
        case "$(influxdb_api GET api/v2/me "${ADMIN_TOKEN}")" in
            2*)
                influxdb_write_private_file "${TOKEN_SHADOW_FILE}" "${token_hash}"
                return 0
                ;;
            401)
                echo "InfluxDB rejects the admin API token in ${ENV_FILE} -- recovering"
                ;;
            *)
                influxdb_warn "could not check the admin API token; leaving ${ENV_FILE} untouched"
                return 1
                ;;
        esac
    fi

    # The default token is the one credential a desynchronized install is still
    # known to share with its database.
    if ! influxdb_token_is_accepted "${PLACEHOLDER_TOKEN}"; then
        influxdb_warn "InfluxDB accepts neither the configured admin token nor the default one; create an operator token in the InfluxDB UI and set INFLUXDB_ADMIN_TOKEN in ${ENV_FILE}"
        return 1
    fi

    read -r auth_id new_token < <(docker exec "${HELPER_CONTAINER}" \
        influx auth create --operator --json -t "${PLACEHOLDER_TOKEN}" \
        -d "HaLOS admin API token" 2>/dev/null |
        awk -F'"' '$2=="id"{id=$4} $2=="token"{print id, $4; exit}')

    if [ -z "${auth_id}" ] || [ -z "${new_token}" ] || ! influxdb_token_is_accepted "${new_token}"; then
        influxdb_warn "could not create a working admin API token; leaving ${ENV_FILE} untouched"
        return 1
    fi
    OPERATOR_TOKEN="${new_token}"

    if ! influxdb_set_admin_token "${new_token}"; then
        influxdb_warn "could not write the new admin API token to ${ENV_FILE}"
        return 1
    fi
    echo "Wrote a fresh operator token to ${ENV_FILE}"
    influxdb_write_private_file "${TOKEN_SHADOW_FILE}" "$(influxdb_hash "${new_token}")"

    influxdb_revoke_default_token "${auth_id}"
}

# --- Password sync -----------------------------------------------------------

influxdb_sync_password() {
    local current_hash password_length
    current_hash=$(influxdb_hash "${ADMIN_PASSWORD}")

    # First run after the feature landed: record what is in use, don't sync.
    if [ ! -f "${SHADOW_FILE}" ]; then
        echo "Recording the current admin password"
        influxdb_write_private_file "${SHADOW_FILE}" "${current_hash}"
        return 0
    fi

    [ "$(cat "${SHADOW_FILE}" 2>/dev/null)" = "${current_hash}" ] && return 0

    password_length=${#ADMIN_PASSWORD}
    if [ "${password_length}" -lt 8 ] || [ "${password_length}" -gt 72 ]; then
        influxdb_warn "InfluxDB passwords must be 8-72 characters (got ${password_length}); the login password has NOT been changed"
        return 1
    fi

    echo "Admin password changed -- syncing to InfluxDB..."
    if ! influxdb_helper_start; then
        influxdb_warn "could not sync the admin password; the previous password stays in effect"
        return 1
    fi

    if ! docker exec "${HELPER_CONTAINER}" influx user password \
        -n "${ADMIN_USER}" \
        -p "${ADMIN_PASSWORD}" \
        -t "${ADMIN_TOKEN}"; then
        influxdb_warn "could not update the password of InfluxDB user '${ADMIN_USER}'; the previous password stays in effect"
        return 1
    fi

    echo "Admin password updated successfully"
    influxdb_write_private_file "${SHADOW_FILE}" "${current_hash}"
}

# --- Main --------------------------------------------------------------------

if [ -z "${CONTAINER_DATA_ROOT:-}" ]; then
    influxdb_warn "CONTAINER_DATA_ROOT is not set; skipping admin token and password management"
    exit 0
fi

ADMIN_USER="${INFLUXDB_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${INFLUXDB_ADMIN_PASSWORD:-halos-default}"
ADMIN_TOKEN="${INFLUXDB_ADMIN_TOKEN:-}"
DATA_DIR="${CONTAINER_DATA_ROOT}"
BOLT_FILE="${DATA_DIR}/db/influxd.bolt"
SHADOW_FILE="${DATA_DIR}/.password-shadow"
TOKEN_SHADOW_FILE="${DATA_DIR}/.token-shadow"

if [ ! -f "${BOLT_FILE}" ]; then
    # Before first setup the container adopts whatever the env file holds, so
    # this is the one moment a locally generated token reaches the database.
    if [ "${ADMIN_TOKEN}" = "${PLACEHOLDER_TOKEN}" ] || [ -z "${ADMIN_TOKEN}" ]; then
        echo "Generating a random admin API token for the initial setup..."
        NEW_TOKEN=$(openssl rand -hex 32)
        if [ -z "${NEW_TOKEN}" ] || ! influxdb_set_admin_token "${NEW_TOKEN}"; then
            influxdb_warn "could not store a generated admin API token in ${ENV_FILE}; InfluxDB will initialize with the default one"
        fi
    fi
    echo "InfluxDB not yet initialized -- skipping password sync"
    exit 0
fi

influxdb_repair_token
influxdb_sync_password

exit 0
