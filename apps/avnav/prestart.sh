#!/bin/bash
# AvNav prestart script
# Patches Signal K handler to connect via host.docker.internal
# (Signal K runs on host network; AvNav runs on bridge network)

set -e

# -- Standard boilerplate (replaces auto-generated prestart) --

# Create runtime directory
RUNTIME_ENV="/run/container-apps/marine-avnav-container/runtime.env"
mkdir -p "$(dirname "$RUNTIME_ENV")"

# Load config values from env files
set -a
[ -f "/etc/container-apps/marine-avnav-container/env.defaults" ] && . "/etc/container-apps/marine-avnav-container/env.defaults"
[ -f "/etc/container-apps/marine-avnav-container/env" ] && . "/etc/container-apps/marine-avnav-container/env"
set +a

# Set hostname
HOSTNAME="$(hostname -s)"
echo "HOSTNAME=$HOSTNAME" > "$RUNTIME_ENV"

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
echo "HALOS_DOMAIN=$HALOS_DOMAIN" >> "$RUNTIME_ENV"

# Compute Homarr URL
HOMARR_URL="http://${HOSTNAME}.local:8080"
echo "HOMARR_URL=$HOMARR_URL" >> "$RUNTIME_ENV"

# -- Signal K handler: use host.docker.internal instead of localhost --

AVNAV_CONFIG="${CONTAINER_DATA_ROOT}/data/avnav_server.xml"

if [ ! -f "${AVNAV_CONFIG}" ]; then
    # First run: create seed config with correct Signal K host.
    # AvNav auto-instantiates all other handlers with defaults.
    echo "AvNav prestart: creating seed avnav_server.xml..."
    mkdir -p "$(dirname "${AVNAV_CONFIG}")"
    chown 1000:1000 "$(dirname "${AVNAV_CONFIG}")"
    cat > "${AVNAV_CONFIG}" << 'EOF'
<AVNServer>
  <AVNSignalKHandler host="host.docker.internal"/>
</AVNServer>
EOF
    chown 1000:1000 "${AVNAV_CONFIG}"
elif grep -q 'AVNSignalKHandler[^>]*host="localhost"' "${AVNAV_CONFIG}"; then
    # Default host="localhost": patch to host.docker.internal
    echo "AvNav prestart: patching Signal K host to host.docker.internal..."
    sed -i 's/\(AVNSignalKHandler[^>]*\)host="localhost"/\1host="host.docker.internal"/' "${AVNAV_CONFIG}"
elif grep -q 'AVNSignalKHandler' "${AVNAV_CONFIG}" && \
     ! grep -q 'AVNSignalKHandler[^>]*host=' "${AVNAV_CONFIG}"; then
    # Handler exists but no explicit host attribute (implicit localhost default)
    echo "AvNav prestart: adding Signal K host attribute..."
    sed -i 's/\(<AVNSignalKHandler\)\([^>]*>\)/\1 host="host.docker.internal"\2/' "${AVNAV_CONFIG}"
else
    echo "AvNav prestart: Signal K host already configured, skipping."
fi
