#!/bin/bash
# Prestart script for signalk-server-container
# Sets correct ownership on data directory for the node user
set -e

# Derive package name from script location
# Script is at /var/lib/container-apps/<package-name>/prestart.sh
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_NAME="$(basename "$SCRIPT_DIR")"
ETC_DIR="/etc/container-apps/${PACKAGE_NAME}"

# Load config values from env files
set -a
[ -f "${ETC_DIR}/env.defaults" ] && . "${ETC_DIR}/env.defaults"
[ -f "${ETC_DIR}/env" ] && . "${ETC_DIR}/env"
set +a

# Ensure data directory has correct ownership
# Signal K runs as user 'node' (UID 1000 by default)
# PUID/PGID are set in env.defaults
if [ -n "$CONTAINER_DATA_ROOT" ] && [ -d "$CONTAINER_DATA_ROOT" ]; then
    chown -R "${PUID:-1000}:${PGID:-1000}" "$CONTAINER_DATA_ROOT"
    echo "Set ownership of $CONTAINER_DATA_ROOT to ${PUID:-1000}:${PGID:-1000}"
fi
