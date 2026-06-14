#!/bin/bash
# Grafana prestart script
# Sets up OIDC authentication with Authelia

set -e

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
    HALOS_DOMAIN="$(hostname -s).local"
fi

echo "Grafana prestart: domain=${HALOS_DOMAIN}"

# Generate OIDC client secret if it doesn't exist
OIDC_SECRET_FILE="${CONTAINER_DATA_ROOT}/oidc-secret"
if [ ! -f "${OIDC_SECRET_FILE}" ]; then
    echo "Generating OIDC client secret..."
    openssl rand -hex 32 > "${OIDC_SECRET_FILE}"
    chmod 600 "${OIDC_SECRET_FILE}"
fi

# Read external port from port registry (assigned by configure-container-routing)
EXTERNAL_PORT=""
PORT_REGISTRY="/etc/halos/port-registry"
if [ -f "${PORT_REGISTRY}" ]; then
    EXTERNAL_PORT=$(grep "^grafana=" "${PORT_REGISTRY}" 2>/dev/null | cut -d= -f2)
fi

if [ -z "${EXTERNAL_PORT}" ]; then
    echo "ERROR: Grafana external port not found in ${PORT_REGISTRY}"
    exit 1
fi

# Write runtime env file with expanded HALOS_DOMAIN
RUNTIME_ENV_DIR="/run/container-apps/marine-grafana-container"
mkdir -p "${RUNTIME_ENV_DIR}"
cat > "${RUNTIME_ENV_DIR}/runtime.env" << EOF
HALOS_DOMAIN=${HALOS_DOMAIN}
GRAFANA_OIDC_CLIENT_SECRET=$(cat "${OIDC_SECRET_FILE}")
HALOS_EXTERNAL_PORT=${EXTERNAL_PORT}
EOF
chmod 600 "${RUNTIME_ENV_DIR}/runtime.env"

# Install OIDC client snippet for Authelia
# Redirect URI uses the port-based URL that Grafana derives from GF_SERVER_ROOT_URL
OIDC_CLIENTS_DIR="/etc/halos/oidc-clients.d"
OIDC_CLIENT_SNIPPET="${OIDC_CLIENTS_DIR}/grafana.yml"
mkdir -p "${OIDC_CLIENTS_DIR}"
cat > "${OIDC_CLIENT_SNIPPET}" << EOF
# Grafana OIDC Client Snippet
# Installed by marine-grafana-container prestart.sh
#
# \${HALOS_DOMAIN} is preserved as a literal placeholder (escaped \\\$ in
# the unquoted heredoc). halos-core-containers' OIDC merger expands it
# to one redirect_uri per configured DNS hostname at merge time.
# \${EXTERNAL_PORT} is the prestart-resolved port and substitutes at
# write time.

client_id: grafana
client_name: Grafana
client_secret_file: /var/lib/container-apps/marine-grafana-container/data/oidc-secret
redirect_uris:
  - 'https://\${HALOS_DOMAIN}:${EXTERNAL_PORT}/login/generic_oauth'
scopes: [openid, profile, email, groups]
consent_mode: implicit
token_endpoint_auth_method: client_secret_basic
EOF

# Ensure data directory exists and has correct ownership (Grafana runs as UID 472)
# Note: Only chown the data subdir, not the oidc-secret which should remain root-owned
mkdir -p "${CONTAINER_DATA_ROOT}/data"
chown -R 472:472 "${CONTAINER_DATA_ROOT}/data"

# --- InfluxDB datasource provisioning ---

INFLUXDB_ENV="/etc/container-apps/marine-influxdb-container/env"
PROVISIONING_DIR="${CONTAINER_DATA_ROOT}/provisioning/datasources"
DATASOURCE_SRC="/var/lib/container-apps/marine-grafana-container/assets/influxdb-datasource.yaml"
DATASOURCE_DST="${PROVISIONING_DIR}/influxdb.yaml"

mkdir -p "${PROVISIONING_DIR}"

if [ -f "${INFLUXDB_ENV}" ]; then
    # Extract only the token — avoid sourcing the entire file
    INFLUXDB_ADMIN_TOKEN=$(grep '^INFLUXDB_ADMIN_TOKEN=' "${INFLUXDB_ENV}" | cut -d= -f2-)

    if [ -n "${INFLUXDB_ADMIN_TOKEN}" ] && [ -f "${DATASOURCE_SRC}" ]; then
        echo "InfluxDB detected -- provisioning datasource"
        cp "${DATASOURCE_SRC}" "${DATASOURCE_DST}"
        # Pass token to Grafana container via runtime.env
        echo "INFLUXDB_TOKEN=${INFLUXDB_ADMIN_TOKEN}" >> "${RUNTIME_ENV_DIR}/runtime.env"
    else
        [ ! -f "${DATASOURCE_SRC}" ] && echo "WARNING: InfluxDB datasource template not found at ${DATASOURCE_SRC}"
        rm -f "${DATASOURCE_DST}"
    fi
else
    rm -f "${DATASOURCE_DST}"
fi

chown -R 472:472 "${PROVISIONING_DIR}"

echo "Grafana prestart complete"
