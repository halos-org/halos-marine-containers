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

# --- datasource provisioning ---
# Grafana only recommends the two datastores, so each datasource is copied in
# when its app is there and taken out when it is not — this is not an
# unconditional static seed.
#
# Removing the file stops Grafana re-provisioning the datasource; it does not
# delete the row Grafana already wrote into its own database. Grafana only
# deletes on an explicit `deleteDatasources` stanza. So after uninstalling an
# app its datasource stays visible and failing until an operator deletes it.
ASSETS_DIR="${ASSETS_DIR:-/var/lib/container-apps/marine-grafana-container/assets}"
PROVISIONING_DIR="${CONTAINER_DATA_ROOT}/provisioning/datasources"
mkdir -p "${PROVISIONING_DIR}"

# The gate is the app's compose file, not its env file under /etc. `apt remove`
# leaves a package in `deinstall ok config-files`, where the env file and the
# systemd unit both survive and only `apt purge` takes them; the compose file is
# payload and goes on either. Verified on a device.
INFLUXDB_COMPOSE="${INFLUXDB_COMPOSE:-/var/lib/container-apps/marine-influxdb-container/docker-compose.yml}"
QUESTDB_COMPOSE="${QUESTDB_COMPOSE:-/var/lib/container-apps/marine-questdb-container/docker-compose.yml}"

# InfluxDB authenticates with a per-device token, which the asset refers to as
# $__env{INFLUXDB_TOKEN} and Grafana expands at startup. The token comes from
# InfluxDB's own env file, so both files have to be there.
INFLUXDB_ENV="${INFLUXDB_ENV:-/etc/container-apps/marine-influxdb-container/env}"
INFLUXDB_DST="${PROVISIONING_DIR}/influxdb.yaml"
INFLUXDB_ADMIN_TOKEN=""
if [ -f "${INFLUXDB_COMPOSE}" ] && [ -f "${INFLUXDB_ENV}" ]; then
    INFLUXDB_ADMIN_TOKEN=$(grep '^INFLUXDB_ADMIN_TOKEN=' "${INFLUXDB_ENV}" | cut -d= -f2-)
fi
if [ -n "${INFLUXDB_ADMIN_TOKEN}" ] && [ -f "${ASSETS_DIR}/influxdb-datasource.yaml" ]; then
    cp "${ASSETS_DIR}/influxdb-datasource.yaml" "${INFLUXDB_DST}"
    echo "INFLUXDB_TOKEN=${INFLUXDB_ADMIN_TOKEN}" >> "$RUNTIME_ENV"
else
    rm -f "${INFLUXDB_DST}"
fi

# QuestDB's credentials are its open-source build's fixed defaults, so the asset
# is complete on its own and nothing about it goes into runtime.env.
QUESTDB_DST="${PROVISIONING_DIR}/questdb.yaml"
if [ -f "${QUESTDB_COMPOSE}" ] && [ -f "${ASSETS_DIR}/questdb-datasource.yaml" ]; then
    cp "${ASSETS_DIR}/questdb-datasource.yaml" "${QUESTDB_DST}"
else
    rm -f "${QUESTDB_DST}"
fi

chown -R 472:472 "${PROVISIONING_DIR}"
