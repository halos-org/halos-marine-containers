#!/usr/bin/env bash
# Exercise the datasource provisioning in apps/grafana/prestart.sh.
#
# The hook decides which Grafana datasources exist from what is installed on the
# host, and that decision is a set of files on disk after it runs -- not
# anything an assertion on the script's text reaches. So each scenario builds an
# install state under a temp directory, runs the hook the way ExecStartPre runs
# it (sourced under `set -e`), and then looks at the provisioning directory.
#
# The install states include the one `apt remove` leaves behind, where the
# compose file is gone and the env file under /etc is not. That asymmetry is the
# whole reason the gate is the compose file, and it is invisible from the hook.
#
# chown is stubbed. The run is unprivileged, so no uid here could ever be the
# container's; what the hook asked for is the ceiling this harness reaches.
#
# Needs no Docker, no network and no root.
#
# Usage: tools/test-grafana-prestart.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${REPO_ROOT}/apps/grafana/prestart.sh"
PACKAGED_ASSETS="${REPO_ROOT}/apps/grafana/assets"
WORKSPACE="$(mktemp -d)"
SHIM_DIR="${WORKSPACE}/shim"
CHOWN_LOG="${WORKSPACE}/chown-calls.log"
trap 'rm -rf "${WORKSPACE}"' EXIT

pass=0
fail=0
ok()    { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()   { printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; fail=$((fail + 1)); }
check() { [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }
scenario() { printf '\n%s\n' "$1"; }

mkdir -p "${SHIM_DIR}"
cat > "${SHIM_DIR}/chown" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${CHOWN_CALL_LOG}"
SHIM
chmod +x "${SHIM_DIR}/chown"

sandbox() { # sandbox <name>
    ROOT="${WORKSPACE}/$1"
    rm -rf "${ROOT:?}"
    DATA="${ROOT}/data"
    ETC="${ROOT}/etc"
    LIB="${ROOT}/lib"
    ASSETS="${PACKAGED_ASSETS}"
    RUNTIME="${ROOT}/runtime.env"
    PROVISIONED="${DATA}/provisioning/datasources"
    mkdir -p "${DATA}" "${ETC}" "${LIB}"
    : > "${RUNTIME}"
}

# `apt install`: payload under /var/lib, conffiles under /etc.
install_influxdb() { # install_influxdb [token]
    mkdir -p "${LIB}/marine-influxdb-container" "${ETC}/marine-influxdb-container"
    printf 'services: {}\n' > "${LIB}/marine-influxdb-container/docker-compose.yml"
    printf 'INFLUXDB_ADMIN_TOKEN=%s\n' "${1-influx-admin-token}" \
        > "${ETC}/marine-influxdb-container/env"
}

install_questdb() {
    mkdir -p "${LIB}/marine-questdb-container" "${ETC}/marine-questdb-container"
    printf 'services: {}\n' > "${LIB}/marine-questdb-container/docker-compose.yml"
    printf 'QUESTDB_MEMORY_LIMIT=768m\n' > "${ETC}/marine-questdb-container/env"
}

# `apt remove`, not purge: the package lands in `deinstall ok config-files`, so
# the payload goes and everything under /etc stays.
remove_app() { rm -f "${LIB}/marine-$1-container/docker-compose.yml"; }

run_hook() {
    : > "${CHOWN_LOG}"
    HOOK_OUTPUT=$(env \
        CONTAINER_DATA_ROOT="${DATA}" \
        RUNTIME_ENV="${RUNTIME}" \
        HALOS_DOMAIN="halos.test" \
        ASSETS_DIR="${ASSETS}" \
        INFLUXDB_COMPOSE="${LIB}/marine-influxdb-container/docker-compose.yml" \
        INFLUXDB_ENV="${ETC}/marine-influxdb-container/env" \
        QUESTDB_COMPOSE="${LIB}/marine-questdb-container/docker-compose.yml" \
        PATH="${SHIM_DIR}:${PATH}" \
        CHOWN_CALL_LOG="${CHOWN_LOG}" \
        bash -c 'set -e; . "$1"' _ "${HOOK}" 2>&1)
    HOOK_STATUS=$?
}

present()   { [ -f "${PROVISIONED}/$1" ] && echo yes || echo no; }
verbatim()  { cmp -s "${PROVISIONED}/$1" "${ASSETS}/$2" && echo yes || echo no; }
token_lines() { grep -c '^INFLUXDB_TOKEN=' "${RUNTIME}"; }

echo "Testing ${HOOK}"

scenario "1. Both datastores installed"
sandbox both
install_influxdb
install_questdb
run_hook
check "hook exits 0" "${HOOK_STATUS}" "0"
check "InfluxDB datasource provisioned" "$(present influxdb.yaml)" "yes"
check "QuestDB datasource provisioned" "$(present questdb.yaml)" "yes"
check "QuestDB datasource is the packaged asset" "$(verbatim questdb.yaml questdb-datasource.yaml)" "yes"
check "the InfluxDB token reaches runtime.env" "$(token_lines)" "1"
check "the provisioning directory is handed to the container's uid" \
    "$(grep -c -- "-R 472:472 ${PROVISIONED}" "${CHOWN_LOG}")" "1"

scenario "2. QuestDB only"
sandbox questdb_only
install_questdb
run_hook
check "hook exits 0" "${HOOK_STATUS}" "0"
check "QuestDB datasource provisioned" "$(present questdb.yaml)" "yes"
check "no InfluxDB datasource" "$(present influxdb.yaml)" "no"
check "nothing about a token in runtime.env" "$(token_lines)" "0"

scenario "3. InfluxDB only"
sandbox influx_only
install_influxdb
run_hook
check "hook exits 0" "${HOOK_STATUS}" "0"
check "InfluxDB datasource provisioned" "$(present influxdb.yaml)" "yes"
check "no QuestDB datasource" "$(present questdb.yaml)" "no"

scenario "4. Neither installed"
sandbox neither
run_hook
check "hook exits 0" "${HOOK_STATUS}" "0"
check "no InfluxDB datasource" "$(present influxdb.yaml)" "no"
check "no QuestDB datasource" "$(present questdb.yaml)" "no"
check "nothing about a token in runtime.env" "$(token_lines)" "0"

# The regression this whole harness exists for. Gating on the env file made
# "the app is gone" false for the ordinary uninstall, because that file
# survives it -- so the datasource stayed, pointing at a container that can no
# longer start.
scenario "5. apt remove takes the datasource with it"
sandbox removal
install_influxdb
install_questdb
run_hook
check "both provisioned to start with" \
    "$(present influxdb.yaml)$(present questdb.yaml)" "yesyes"
remove_app questdb
run_hook
check "hook exits 0" "${HOOK_STATUS}" "0"
check "QuestDB env file survived the remove" \
    "$([ -f "${ETC}/marine-questdb-container/env" ] && echo yes || echo no)" "yes"
check "QuestDB datasource removed anyway" "$(present questdb.yaml)" "no"
check "InfluxDB datasource untouched" "$(present influxdb.yaml)" "yes"
remove_app influxdb
: > "${RUNTIME}"
run_hook
check "hook exits 0" "${HOOK_STATUS}" "0"
check "InfluxDB env file survived the remove" \
    "$([ -f "${ETC}/marine-influxdb-container/env" ] && echo yes || echo no)" "yes"
check "InfluxDB datasource removed anyway" "$(present influxdb.yaml)" "no"
check "no token written for a removed InfluxDB" "$(token_lines)" "0"

scenario "6. An installed InfluxDB whose env file carries no token"
sandbox empty_token
install_influxdb ""
install_questdb
run_hook
check "hook exits 0" "${HOOK_STATUS}" "0"
check "no InfluxDB datasource" "$(present influxdb.yaml)" "no"
check "no empty token in runtime.env" "$(token_lines)" "0"
check "QuestDB is unaffected" "$(present questdb.yaml)" "yes"

# The assets are package payload. A datasource file naming $__env{} for a value
# nothing supplies, or a copy of a file that was dropped from the .deb, both
# read as "provisioned" to everything downstream.
scenario "7. Assets missing from the package"
sandbox no_assets
install_influxdb
install_questdb
ASSETS="${ROOT}/empty-assets"
mkdir -p "${ASSETS}"
run_hook
check "hook exits 0" "${HOOK_STATUS}" "0"
check "no InfluxDB datasource" "$(present influxdb.yaml)" "no"
check "no QuestDB datasource" "$(present questdb.yaml)" "no"
check "no token for a datasource that was never written" "$(token_lines)" "0"

printf '\nPASS=%s FAIL=%s\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
