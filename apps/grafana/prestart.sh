#!/bin/bash
# Grafana prestart script
# Sets up OIDC authentication with Authelia

set -e

# Derive HALOS_DOMAIN from hostname if not set
if [ -z "${HALOS_DOMAIN}" ]; then
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

# Write runtime env file with expanded HALOS_DOMAIN
RUNTIME_ENV_DIR="/run/container-apps/marine-grafana-container"
mkdir -p "${RUNTIME_ENV_DIR}"
cat > "${RUNTIME_ENV_DIR}/runtime.env" << EOF
HALOS_DOMAIN=${HALOS_DOMAIN}
GRAFANA_OIDC_CLIENT_SECRET=$(cat "${OIDC_SECRET_FILE}")
EOF
chmod 600 "${RUNTIME_ENV_DIR}/runtime.env"

# Install OIDC client snippet for Authelia
OIDC_CLIENTS_DIR="/etc/halos/oidc-clients.d"
OIDC_CLIENT_SNIPPET="${OIDC_CLIENTS_DIR}/grafana.yml"
if [ ! -f "${OIDC_CLIENT_SNIPPET}" ]; then
    echo "Installing OIDC client snippet for Authelia..."
    mkdir -p "${OIDC_CLIENTS_DIR}"
    cat > "${OIDC_CLIENT_SNIPPET}" << 'EOF'
# Grafana OIDC Client Snippet
# Installed by marine-grafana-container prestart.sh
# Authelia's prestart script merges all snippets into oidc-clients.yml

client_id: grafana
client_name: Grafana
client_secret_file: /var/lib/container-apps/marine-grafana-container/data/oidc-secret
redirect_uris:
  - 'https://grafana.${HALOS_DOMAIN}/login/generic_oauth'
scopes: [openid, profile, email, groups]
consent_mode: implicit
require_pkce: true
pkce_challenge_method: S256
token_endpoint_auth_method: client_secret_basic
EOF
    echo "OIDC client snippet installed to ${OIDC_CLIENT_SNIPPET}"
    echo "NOTE: Restart Authelia to pick up the new OIDC client"
fi

# Ensure data directory exists and has correct ownership (Grafana runs as UID 472)
mkdir -p "${CONTAINER_DATA_ROOT}/data"
chown -R 472:472 "${CONTAINER_DATA_ROOT}"

echo "Grafana prestart complete"
