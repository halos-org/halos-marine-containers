#!/bin/bash
# Signal K Server app-prestart hook (sourced by the generated framework prestart).
# OIDC is declarative now (routing.auth.mode: oidc): the framework provisions the
# client secret, writes the Authelia snippet, and appends SIGNALK_OIDC_CLIENT_SECRET
# /_ISSUER/_REDIRECT_URI to runtime.env. This hook keeps the Signal K-specific
# steps: the security.json bootstrap, external-URL advertising, and the InfluxDB
# logging plugin.

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

# Signal K advertises its external URL via mDNS from these. EXTERNALHOST strips
# the .local suffix that Signal K's dnssd library re-appends; the external port
# comes from the routing registry, defaulting to the HTTPS port. Appended to the
# framework-owned runtime.env (the OIDC vars are written there by the framework).
EXTERNAL_PORT="$(grep '^signalk-server=' /etc/halos/port-registry 2>/dev/null | cut -d= -f2)"
{
    echo "EXTERNALHOST=${HALOS_DOMAIN%.local}"
    echo "EXTERNALPORT=${EXTERNAL_PORT:-443}"
    # Requires upstream EXTERNALSSL support: https://github.com/SignalK/signalk-server/pull/2484
    echo "EXTERNALSSL=1"
} >> "$RUNTIME_ENV"

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
