#!/bin/bash
# Signal K Server prestart script
# Creates security.json with default admin user if not exists

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

# Read external port from port registry (assigned by configure-container-routing)
EXTERNAL_PORT=""
PORT_REGISTRY="/etc/halos/port-registry"
if [ -f "${PORT_REGISTRY}" ]; then
    EXTERNAL_PORT=$(grep "^signalk-server=" "${PORT_REGISTRY}" 2>/dev/null | cut -d= -f2)
fi

# EXTERNALHOST strips .local suffix — Signal K's mDNS library (dnssd) appends it
cat > "${RUNTIME_ENV_DIR}/runtime.env" << EOF
HALOS_DOMAIN=${HALOS_DOMAIN}
EXTERNALHOST=${HALOS_DOMAIN%.local}
EXTERNALPORT=${EXTERNAL_PORT:-443}
# Requires upstream EXTERNALSSL support: https://github.com/SignalK/signalk-server/pull/2484
EXTERNALSSL=1
SIGNALK_OIDC_CLIENT_SECRET=$(cat "${OIDC_SECRET_FILE}")
SIGNALK_OIDC_ISSUER=https://${HALOS_DOMAIN}/sso
SIGNALK_OIDC_REDIRECT_URI=https://${HALOS_DOMAIN}/signalk-server/signalk/v1/auth/oidc/callback
EOF
chmod 600 "${RUNTIME_ENV_DIR}/runtime.env"

# Install OIDC client snippet for Authelia
# Always written (not guarded) so redirect URIs stay current across upgrades
OIDC_CLIENTS_DIR="/etc/halos/oidc-clients.d"
OIDC_CLIENT_SNIPPET="${OIDC_CLIENTS_DIR}/signalk.yml"
mkdir -p "${OIDC_CLIENTS_DIR}"
cat > "${OIDC_CLIENT_SNIPPET}" << 'EOF'
# Signal K OIDC Client Snippet
# Installed by marine-signalk-server-container prestart.sh
# Authelia's prestart script merges all snippets into oidc-clients.yml
# Redirect URI uses path redirect (/signalk-server/) which 302s to the port URL

client_id: signalk
client_name: Signal K Server
client_secret_file: /var/lib/container-apps/marine-signalk-server-container/data/oidc-secret
redirect_uris:
  - 'https://${HALOS_DOMAIN}/signalk-server/signalk/v1/auth/oidc/callback'
scopes: [openid, profile, email, groups]
consent_mode: implicit
token_endpoint_auth_method: client_secret_post
EOF

# --- InfluxDB plugin provisioning ---

INFLUXDB_ENV="/etc/container-apps/marine-influxdb-container/env"
PLUGIN_CONFIG_DIR="${SIGNALK_DATA}/plugin-config-data"
PLUGIN_CONFIG="${PLUGIN_CONFIG_DIR}/signalk-to-influxdb2.json"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [ -f "${INFLUXDB_ENV}" ]; then
    INFLUXDB_ADMIN_TOKEN=$(grep '^INFLUXDB_ADMIN_TOKEN=' "${INFLUXDB_ENV}" | cut -d= -f2-)

    if [ -n "${INFLUXDB_ADMIN_TOKEN}" ]; then
        # Install plugin if not already present
        if [ ! -d "${SIGNALK_DATA}/node_modules/signalk-to-influxdb2" ]; then
            SIGNALK_IMAGE=$(grep -oP 'image:\s*\K\S+' "${SCRIPT_DIR}/docker-compose.yml" | head -1)
            echo "Installing signalk-to-influxdb2 plugin..."
            if timeout 120 docker run --rm --entrypoint npm \
                -v "${SIGNALK_DATA}:/home/node/.signalk" \
                -u 1000:1000 \
                "${SIGNALK_IMAGE}" \
                install --prefix /home/node/.signalk signalk-to-influxdb2; then
                echo "Plugin installed successfully"
            else
                echo "WARNING: Failed to install signalk-to-influxdb2 (no internet?). Will retry on next restart."
            fi
        fi

        # Write plugin config (first time only) or update token
        mkdir -p "${PLUGIN_CONFIG_DIR}"
        if [ ! -f "${PLUGIN_CONFIG}" ]; then
            cat > "${PLUGIN_CONFIG}" << PLUGINEOF
{
  "enabled": true,
  "configuration": {
    "influxes": [
      {
        "url": "http://localhost:8086",
        "token": "${INFLUXDB_ADMIN_TOKEN}",
        "org": "marine",
        "bucket": "marine",
        "onlySelf": true,
        "resolution": 1000
      }
    ]
  }
}
PLUGINEOF
            echo "InfluxDB plugin configured"
        else
            # Update token in existing config without overwriting other settings
            if python3 -c "
import json, sys
with open('${PLUGIN_CONFIG}', 'r') as f:
    cfg = json.load(f)
influxes = cfg.get('configuration', {}).get('influxes', [])
if influxes:
    influxes[0]['token'] = '${INFLUXDB_ADMIN_TOKEN}'
with open('${PLUGIN_CONFIG}', 'w') as f:
    json.dump(cfg, f, indent=2)
"; then
                echo "InfluxDB plugin token updated"
            else
                echo "WARNING: Failed to update InfluxDB token in plugin config"
            fi
        fi
    fi
fi

# Ensure data directory is owned by node user (UID 1000)
# settings.json is installed via default-data/ at package install time
# The container runs as node:node, but prestart runs as root
chown -R 1000:1000 "${CONTAINER_DATA_ROOT}"
