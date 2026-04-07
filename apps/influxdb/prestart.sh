#!/bin/bash
# Prestart script for marine-influxdb-container
# Handles runtime env setup and admin password sync after first-time init.
set -e

PACKAGE_NAME="marine-influxdb-container"
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
cat > "${RUNTIME_ENV}" << EOF
HOSTNAME=${HOSTNAME}
HALOS_DOMAIN=${HOSTNAME}.local
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
    echo "${CURRENT_HASH}" > "${SHADOW_FILE}"
    chmod 600 "${SHADOW_FILE}"
    exit 0
fi

PREVIOUS_HASH=$(cat "${SHADOW_FILE}")

if [ "${CURRENT_HASH}" = "${PREVIOUS_HASH}" ]; then
    exit 0
fi

# InfluxDB requires passwords between 8 and 72 characters
PASSWORD_LEN=${#ADMIN_PASSWORD}
if [ "${PASSWORD_LEN}" -lt 8 ] || [ "${PASSWORD_LEN}" -gt 72 ]; then
    echo "ERROR: Password must be 8-72 characters (got ${PASSWORD_LEN}). Skipping sync."
    echo "The InfluxDB login password has NOT been changed."
    exit 1
fi

echo "Admin password changed -- syncing to InfluxDB..."

TEMP_CONTAINER="influxdb-password-sync"
INFLUXDB_IMAGE="influxdb:2.8.0"

cleanup() {
    docker rm -f "${TEMP_CONTAINER}" 2>/dev/null || true
}
trap cleanup EXIT

# Clean up any leftover from a previous failed run
cleanup

# Start temporary InfluxDB with same data volumes
docker run -d --name "${TEMP_CONTAINER}" \
    -v "${DATA_DIR}/config:/etc/influxdb2" \
    -v "${DATA_DIR}/db:/var/lib/influxdb2" \
    "${INFLUXDB_IMAGE}" >/dev/null

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
echo "${CURRENT_HASH}" > "${SHADOW_FILE}"
chmod 600 "${SHADOW_FILE}"
