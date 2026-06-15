#!/bin/bash
# Grafana app-prestart hook (sourced by the generated framework prestart).
# OIDC is declarative now (routing.auth.mode: oidc): the framework provisions
# the client secret, resolves the external port, writes the Authelia snippet,
# and appends GRAFANA_OIDC_CLIENT_SECRET + HALOS_EXTERNAL_PORT to runtime.env.
# This hook only covers the residual, app-specific steps.

# The framework computes HOMARR_URL from web_ui.port (3000), but Grafana is
# reached through Traefik on its dedicated external HTTPS port, not the internal
# container port. Override with the port-based URL; the later value wins when the
# unit loads runtime.env as an EnvironmentFile.
GRAFANA_EXTERNAL_PORT="$(grep '^grafana=' /etc/halos/port-registry 2>/dev/null | cut -d= -f2)"
if [ -n "${GRAFANA_EXTERNAL_PORT}" ]; then
    echo "HOMARR_URL=https://${HALOS_DOMAIN}:${GRAFANA_EXTERNAL_PORT}" >> "$RUNTIME_ENV"
fi

# Grafana runs as UID 472 and writes its database under the data volume.
mkdir -p "${CONTAINER_DATA_ROOT}/data"
chown -R 472:472 "${CONTAINER_DATA_ROOT}/data"

# --- InfluxDB datasource provisioning ---
# Provisioning is conditional on InfluxDB (Grafana only recommends it), so the
# datasource is copied in when InfluxDB + its token are present and removed
# otherwise — it is not unconditional static seed. Grafana expands
# $__env{INFLUXDB_TOKEN} (supplied via runtime.env) at startup.
INFLUXDB_ENV="/etc/container-apps/marine-influxdb-container/env"
PROVISIONING_DIR="${CONTAINER_DATA_ROOT}/provisioning/datasources"
DATASOURCE_SRC="/var/lib/container-apps/marine-grafana-container/assets/influxdb-datasource.yaml"
DATASOURCE_DST="${PROVISIONING_DIR}/influxdb.yaml"
mkdir -p "${PROVISIONING_DIR}"
if [ -f "${INFLUXDB_ENV}" ]; then
    INFLUXDB_ADMIN_TOKEN=$(grep '^INFLUXDB_ADMIN_TOKEN=' "${INFLUXDB_ENV}" | cut -d= -f2-)
    if [ -n "${INFLUXDB_ADMIN_TOKEN}" ] && [ -f "${DATASOURCE_SRC}" ]; then
        cp "${DATASOURCE_SRC}" "${DATASOURCE_DST}"
        echo "INFLUXDB_TOKEN=${INFLUXDB_ADMIN_TOKEN}" >> "$RUNTIME_ENV"
    else
        rm -f "${DATASOURCE_DST}"
    fi
else
    rm -f "${DATASOURCE_DST}"
fi
chown -R 472:472 "${PROVISIONING_DIR}"
