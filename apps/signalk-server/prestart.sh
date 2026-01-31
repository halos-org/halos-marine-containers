#!/bin/bash
# Signal K Server prestart script
# Creates security.json with default admin user if not exists

set -e

# Derive HALOS_DOMAIN from hostname if not set
if [ -z "${HALOS_DOMAIN}" ]; then
    HALOS_DOMAIN="$(hostname -s).local"
fi

SIGNALK_DATA="${CONTAINER_DATA_ROOT}/data"
SECURITY_FILE="${SIGNALK_DATA}/security.json"

# Create data directory if needed
mkdir -p "${SIGNALK_DATA}"

# Only create security.json if it doesn't exist
if [ ! -f "${SECURITY_FILE}" ]; then
    echo "Creating initial security.json with default admin user..."

    # Generate a random password (32 character hex string)
    ADMIN_PASSWORD=$(openssl rand -hex 16)

    # Hash the password using Python bcrypt (via stdin for robustness)
    # python3-bcrypt is a dependency of the package
    HASHED_PASSWORD=$(printf '%s' "${ADMIN_PASSWORD}" | python3 -c "import sys, bcrypt; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt()).decode())")

    # Generate a secret key for JWT tokens
    SECRET_KEY=$(openssl rand -hex 32)

    # Create security.json
    cat > "${SECURITY_FILE}" << EOF
{
  "strategy": "./tokensecurity",
  "users": [
    {
      "username": "admin",
      "type": "admin",
      "password": "${HASHED_PASSWORD}"
    }
  ],
  "allow_readonly": true,
  "secretKey": "${SECRET_KEY}"
}
EOF

    # Set proper ownership (match container user - node:node is 1000:1000)
    chown 1000:1000 "${SECURITY_FILE}"

    echo "Security initialized with admin user."
    echo "NOTE: Local admin password stored in ${CONTAINER_DATA_ROOT}/admin-password"
    echo "This is a fallback for emergency access. Use OIDC for regular login."

    # Store the password for emergency recovery
    echo "${ADMIN_PASSWORD}" > "${CONTAINER_DATA_ROOT}/admin-password"
    chmod 600 "${CONTAINER_DATA_ROOT}/admin-password"
fi

# Generate OIDC client secret if it doesn't exist
OIDC_SECRET_FILE="${CONTAINER_DATA_ROOT}/oidc-secret"
if [ ! -f "${OIDC_SECRET_FILE}" ]; then
    echo "Generating OIDC client secret..."
    openssl rand -hex 32 > "${OIDC_SECRET_FILE}"
    chmod 600 "${OIDC_SECRET_FILE}"
    echo "OIDC client secret stored in ${OIDC_SECRET_FILE}"
fi

# Write runtime env file for systemd to load
# HALOS_DOMAIN is needed for docker-compose label substitution
# OIDC settings expand HALOS_DOMAIN since systemd EnvironmentFile doesn't
RUNTIME_ENV_DIR="/run/container-apps/marine-signalk-server-container"
mkdir -p "${RUNTIME_ENV_DIR}"
cat > "${RUNTIME_ENV_DIR}/runtime.env" << EOF
HALOS_DOMAIN=${HALOS_DOMAIN}
SIGNALK_OIDC_CLIENT_SECRET=$(cat "${OIDC_SECRET_FILE}")
SIGNALK_OIDC_ISSUER=https://auth.${HALOS_DOMAIN}
SIGNALK_OIDC_REDIRECT_URI=https://signalk.${HALOS_DOMAIN}/signalk/v1/auth/oidc/callback
EOF
chmod 600 "${RUNTIME_ENV_DIR}/runtime.env"

# Install OIDC client snippet for Authelia
OIDC_CLIENTS_DIR="/etc/halos/oidc-clients.d"
OIDC_CLIENT_SNIPPET="${OIDC_CLIENTS_DIR}/signalk.yml"
if [ ! -f "${OIDC_CLIENT_SNIPPET}" ]; then
    echo "Installing OIDC client snippet for Authelia..."
    mkdir -p "${OIDC_CLIENTS_DIR}"
    cat > "${OIDC_CLIENT_SNIPPET}" << 'EOF'
# Signal K OIDC Client Snippet
# Installed by marine-signalk-server-container prestart.sh
# Authelia's prestart script merges all snippets into oidc-clients.yml

client_id: signalk
client_name: Signal K Server
client_secret_file: /var/lib/container-apps/marine-signalk-server-container/data/oidc-secret
redirect_uris:
  - 'https://signalk.${HALOS_DOMAIN}/signalk/v1/auth/oidc/callback'
scopes: [openid, profile, email, groups]
consent_mode: implicit
token_endpoint_auth_method: client_secret_post
EOF
    echo "OIDC client snippet installed to ${OIDC_CLIENT_SNIPPET}"
    echo "NOTE: Restart Authelia to pick up the new OIDC client"
fi

# Create settings.json with reverse proxy settings if it doesn't exist
# Signal K runs behind Traefik, so we need ssl=false and trustProxy=true
SETTINGS_FILE="${SIGNALK_DATA}/settings.json"
if [ ! -f "${SETTINGS_FILE}" ]; then
    echo "Creating settings.json with reverse proxy settings..."
    cat > "${SETTINGS_FILE}" << EOF
{
  "ssl": false,
  "trustProxy": true
}
EOF
    chown 1000:1000 "${SETTINGS_FILE}"
fi

# Ensure data directory is owned by node user (UID 1000)
# The container runs as node:node, but prestart runs as root
chown -R 1000:1000 "${CONTAINER_DATA_ROOT}"
