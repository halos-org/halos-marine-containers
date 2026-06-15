#!/bin/bash
# AvNav app-prestart hook (sourced by the generated framework prestart).
# Keeps AvNav's Signal K handler pointed at host.docker.internal: Signal K
# runs on the host network while AvNav runs on a bridge network. The seed
# avnav_server.xml ships via default-data/; this hook only corrects the
# handler host if AvNav rewrites it back to localhost.

AVNAV_CONFIG="${CONTAINER_DATA_ROOT}/data/avnav_server.xml"

if [ ! -f "${AVNAV_CONFIG}" ]; then
    echo "AvNav prestart: ${AVNAV_CONFIG} not present yet, skipping host patch."
elif grep -q 'AVNSignalKHandler[^>]*host="localhost"' "${AVNAV_CONFIG}"; then
    echo "AvNav prestart: patching Signal K host to host.docker.internal..."
    sed -i 's/\(AVNSignalKHandler[^>]*\)host="localhost"/\1host="host.docker.internal"/' "${AVNAV_CONFIG}"
elif grep -q 'AVNSignalKHandler' "${AVNAV_CONFIG}" && \
     ! grep -q 'AVNSignalKHandler[^>]*host=' "${AVNAV_CONFIG}"; then
    echo "AvNav prestart: adding Signal K host attribute..."
    sed -i 's/\(<AVNSignalKHandler\)\([^>]*>\)/\1 host="host.docker.internal"\2/' "${AVNAV_CONFIG}"
else
    echo "AvNav prestart: Signal K host already configured, skipping."
fi
