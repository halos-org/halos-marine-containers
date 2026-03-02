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

# Read external port from port registry (assigned by configure-container-routing)
EXTERNAL_PORT=""
PORT_REGISTRY="/etc/halos/port-registry"
if [ -f "${PORT_REGISTRY}" ]; then
    EXTERNAL_PORT=$(grep "^grafana=" "${PORT_REGISTRY}" 2>/dev/null | cut -d= -f2)
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
# Always written (not guarded) so redirect URIs stay current across upgrades
OIDC_CLIENTS_DIR="/etc/halos/oidc-clients.d"
OIDC_CLIENT_SNIPPET="${OIDC_CLIENTS_DIR}/grafana.yml"
mkdir -p "${OIDC_CLIENTS_DIR}"
cat > "${OIDC_CLIENT_SNIPPET}" << 'EOF'
# Grafana OIDC Client Snippet
# Installed by marine-grafana-container prestart.sh
# Authelia's prestart script merges all snippets into oidc-clients.yml
# Redirect URI uses path redirect (/grafana/) which 302s to the port URL

client_id: grafana
client_name: Grafana
client_secret_file: /var/lib/container-apps/marine-grafana-container/data/oidc-secret
redirect_uris:
  - 'https://${HALOS_DOMAIN}/grafana/login/generic_oauth'
scopes: [openid, profile, email, groups]
consent_mode: implicit
token_endpoint_auth_method: client_secret_basic
# Note: PKCE is enforced client-side via GF_AUTH_GENERIC_OAUTH_USE_PKCE=true
EOF

# Ensure data directory exists and has correct ownership (Grafana runs as UID 472)
# Note: Only chown the data subdir, not the oidc-secret which should remain root-owned
mkdir -p "${CONTAINER_DATA_ROOT}/data"
chown -R 472:472 "${CONTAINER_DATA_ROOT}/data"

echo "Grafana prestart complete"
