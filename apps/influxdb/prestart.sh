#!/bin/bash
# Prestart script for marine-influxdb-container
# Handles runtime env setup and admin password sync after first-time init.
set -e

PACKAGE_NAME="marine-influxdb-container"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ETC_DIR="/etc/container-apps/${PACKAGE_NAME}"
RUN_DIR="/run/container-apps/${PACKAGE_NAME}"
RUNTIME_ENV="${RUN_DIR}/runtime.env"

# Load config values from env files
set -a
[ -f "${ETC_DIR}/env.defaults" ] && . "${ETC_DIR}/env.defaults"
[ -f "${ETC_DIR}/env" ] && . "${ETC_DIR}/env"
set +a

# Write standard runtime env vars
mkdir -p "${RUN_DIR}"
HOSTNAME="$(hostname -s)"

# Resolve HALOS_DOMAIN from the canonical hostname in
# /etc/halos/hostnames.conf via the shared loader (shipped by
# halos-core-containers). Recomputed unconditionally: systemd loads the
# previous runtime.env as an EnvironmentFile, so honoring an already-set
# HALOS_DOMAIN would pin the first-resolved value forever. Fall back to
# ${hostname}.local only when the loader is unavailable.
LIB_HOSTNAMES="/usr/lib/halos-core-containers/lib-hostnames.sh"
if [ -r "${LIB_HOSTNAMES}" ]; then
    # shellcheck source=/dev/null
    . "${LIB_HOSTNAMES}"
    halos_load_hostnames
    HALOS_DOMAIN="$(halos_canonical_hostname)"
else
    HALOS_DOMAIN="${HOSTNAME}.local"
fi

cat > "${RUNTIME_ENV}" << EOF
HOSTNAME=${HOSTNAME}
HALOS_DOMAIN=${HALOS_DOMAIN}
HOMARR_URL=http://${HOSTNAME}.local:8086/
EOF

# --- Token generation ---

PLACEHOLDER_TOKEN="halos-default-token-change-in-production"
ENV_FILE="${ETC_DIR}/env"

# Replace placeholder token with a random one before first init
if [ "${INFLUXDB_ADMIN_TOKEN}" = "${PLACEHOLDER_TOKEN}" ] || [ -z "${INFLUXDB_ADMIN_TOKEN}" ]; then
    NEW_TOKEN=$(openssl rand -hex 32)
    echo "Generating random admin API token..."

    if [ -f "${ENV_FILE}" ]; then
        # Replace or append token in existing env file
        if grep -q "^INFLUXDB_ADMIN_TOKEN=" "${ENV_FILE}"; then
            sed -i "s|^INFLUXDB_ADMIN_TOKEN=.*|INFLUXDB_ADMIN_TOKEN=${NEW_TOKEN}|" "${ENV_FILE}"
        else
            echo "INFLUXDB_ADMIN_TOKEN=${NEW_TOKEN}" >> "${ENV_FILE}"
        fi
    else
        mkdir -p "${ETC_DIR}"
        echo "INFLUXDB_ADMIN_TOKEN=${NEW_TOKEN}" > "${ENV_FILE}"
    fi

    INFLUXDB_ADMIN_TOKEN="${NEW_TOKEN}"
fi

# --- Password sync ---

if [ -z "${CONTAINER_DATA_ROOT}" ]; then
    echo "ERROR: CONTAINER_DATA_ROOT is not set"
    exit 1
fi

ADMIN_USER="${INFLUXDB_ADMIN_USER:-admin}"
ADMIN_PASSWORD="${INFLUXDB_ADMIN_PASSWORD:-halos-default}"
ADMIN_TOKEN="${INFLUXDB_ADMIN_TOKEN}"
DATA_DIR="${CONTAINER_DATA_ROOT}"
BOLT_FILE="${DATA_DIR}/db/influxd.bolt"
SHADOW_FILE="${DATA_DIR}/.password-shadow"

# Only sync if DB has been initialized
if [ ! -f "${BOLT_FILE}" ]; then
    echo "InfluxDB not yet initialized -- skipping password sync"
    exit 0
fi

CURRENT_HASH=$(echo -n "${ADMIN_PASSWORD}" | sha256sum | cut -d' ' -f1)

# First restart after upgrade: create shadow, don't sync
if [ ! -f "${SHADOW_FILE}" ]; then
    echo "Creating initial password shadow"
    SHADOW_TMP=$(mktemp "${SHADOW_FILE}.XXXXXX")
    echo "${CURRENT_HASH}" > "${SHADOW_TMP}"
    chmod 600 "${SHADOW_TMP}"
    mv "${SHADOW_TMP}" "${SHADOW_FILE}"
    exit 0
fi

PREVIOUS_HASH=$(cat "${SHADOW_FILE}")

if [ "${CURRENT_HASH}" = "${PREVIOUS_HASH}" ]; then
    exit 0
fi

# InfluxDB requires passwords between 8 and 72 characters
PASSWORD_LEN=${#ADMIN_PASSWORD}
if [ "${PASSWORD_LEN}" -lt 8 ] || [ "${PASSWORD_LEN}" -gt 72 ]; then
    echo "WARNING: Password must be 8-72 characters (got ${PASSWORD_LEN}). Skipping sync."
    echo "The InfluxDB login password has NOT been changed."
    exit 0
fi

echo "Admin password changed -- syncing to InfluxDB..."

TEMP_CONTAINER="influxdb-password-sync"
INFLUXDB_IMAGE=$(grep -oP 'image:\s*\K\S+' "${SCRIPT_DIR}/docker-compose.yml" | head -1)
if [ -z "${INFLUXDB_IMAGE}" ]; then
    echo "ERROR: Could not determine InfluxDB image from docker-compose.yml"
    exit 1
fi

cleanup() {
    docker rm -f "${TEMP_CONTAINER}" 2>/dev/null || true
}
trap cleanup EXIT

# Clean up any leftover from a previous failed run
cleanup

# Start temporary InfluxDB with same data volumes
if ! docker run -d --name "${TEMP_CONTAINER}" \
    -v "${DATA_DIR}/config:/etc/influxdb2" \
    -v "${DATA_DIR}/db:/var/lib/influxdb2" \
    "${INFLUXDB_IMAGE}" >/dev/null; then
    echo "ERROR: Failed to start temporary InfluxDB container"
    exit 1
fi

# Wait for readiness (up to 30s)
for i in $(seq 1 30); do
    if docker exec "${TEMP_CONTAINER}" influx ping 2>/dev/null; then
        break
    fi
    if [ "$i" -eq 30 ]; then
        echo "ERROR: Temporary InfluxDB failed to become ready"
        exit 1
    fi
    sleep 1
done

# Change the password
if ! docker exec "${TEMP_CONTAINER}" influx user password \
    -n "${ADMIN_USER}" \
    -p "${ADMIN_PASSWORD}" \
    -t "${ADMIN_TOKEN}"; then
    echo "ERROR: Failed to update admin password"
    exit 1
fi

echo "Admin password updated successfully"
SHADOW_TMP=$(mktemp "${SHADOW_FILE}.XXXXXX")
echo "${CURRENT_HASH}" > "${SHADOW_TMP}"
chmod 600 "${SHADOW_TMP}"
mv "${SHADOW_TMP}" "${SHADOW_FILE}"
