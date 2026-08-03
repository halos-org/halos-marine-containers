#!/bin/bash
# Exercise apps/signalk-server/prestart.sh with stubbed chown/bcrypt.
#
# The hook writes three files holding secrets and decides which paths change
# owner. Both are properties of the filesystem after it runs, not of its text,
# so this runs it against a sandbox: no root, no container, no InfluxDB.
#
# Usage: tools/test-prestart.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${REPO_ROOT}/apps/signalk-server/prestart.sh"
REAL_PYTHON3="$(command -v python3)"
export REAL_PYTHON3
pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; fail=$((fail + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }

# Not stat: the BSD and GNU flags collide -- GNU reads `-f` as --file-system and
# prints a filesystem report instead of failing, so the fallback never fires.
mode() {
    "${REAL_PYTHON3}" -c \
        'import os, sys; print(format(os.stat(sys.argv[1]).st_mode & 0o777, "03o"))' "$1"
}

setup() {
    SANDBOX="$(mktemp -d)"
    DATA="${SANDBOX}/data"
    SK="${DATA}/data"
    mkdir -p "${SK}" "${SANDBOX}/bin"
    STUB_LOG="${SANDBOX}/chown.log"; : > "${STUB_LOG}"
    export STUB_LOG

    cat > "${SANDBOX}/bin/chown" <<'STUB'
#!/bin/bash
echo "chown $*" >> "${STUB_LOG}"
STUB
    # bcrypt is not installed on a dev machine; every other python3 call is real.
    cat > "${SANDBOX}/bin/python3" <<'STUB'
#!/bin/bash
if [ "${1:-}" = "-c" ] && [[ "${2:-}" == *bcrypt* ]]; then
    cat >/dev/null
    echo '$2b$12$stubhashstubhashstubhashstubhashstubhas'
    exit 0
fi
exec "${REAL_PYTHON3}" "$@"
STUB
    chmod 755 "${SANDBOX}/bin"/*
}

teardown() { rm -rf "${SANDBOX}"; }

run_hook() {  # echoes exit status
    PATH="${SANDBOX}/bin:${PATH}" \
        CONTAINER_DATA_ROOT="${DATA}" \
        RUNTIME_ENV="${SANDBOX}/runtime.env" \
        HALOS_DOMAIN="test.local" \
        INFLUXDB_ENV="${SANDBOX}/influxdb.env" \
        bash "${HOOK}" > "${SANDBOX}/out" 2>&1
    echo $?
}

influx_available() {  # $1 = token to publish
    mkdir -p "${SK}/node_modules/signalk-to-influxdb2"
    printf 'INFLUXDB_ADMIN_TOKEN=%s\n' "$1" > "${SANDBOX}/influxdb.env"
}

echo "prestart.sh behaviour"

setup
check "fresh install exits 0" "$(run_hook)" "0"
check "  security.json is 0600" "$(mode "${SK}/security.json")" "600"
check "  admin-password is 0600" "$(mode "${DATA}/admin-password")" "600"
teardown

setup
influx_available tok-fresh
check "influx config is written" "$(run_hook)" "0"
check "  at 0600" "$(mode "${SK}/plugin-config-data/signalk-to-influxdb2.json")" "600"
grep -q tok-fresh "${SK}/plugin-config-data/signalk-to-influxdb2.json" &&
    ok "  with the token" || bad "  with the token" "token missing from config"
teardown

# What an upgraded device looks like: files the old hook wrote 0644, and the two
# root-only secrets it handed to uid 1000 with its recursive chown.
setup
printf '{"secretKey":"old"}\n' > "${SK}/security.json"
chmod 644 "${SK}/security.json"
mkdir -p "${SK}/plugin-config-data"
printf '{"configuration":{"influxes":[{"token":"stale"}]}}\n' \
    > "${SK}/plugin-config-data/signalk-to-influxdb2.json"
chmod 644 "${SK}/plugin-config-data/signalk-to-influxdb2.json"
: > "${DATA}/admin-password"
: > "${DATA}/oidc-secret"
influx_available tok-rotated
check "upgraded device exits 0" "$(run_hook)" "0"
check "  security.json converges to 0600" "$(mode "${SK}/security.json")" "600"
check "  influx config converges to 0600" \
    "$(mode "${SK}/plugin-config-data/signalk-to-influxdb2.json")" "600"
grep -q '"secretKey": *"old"' "${SK}/security.json" &&
    ok "  existing security.json is left alone" ||
    bad "  existing security.json is left alone" "$(cat "${SK}/security.json")"
grep -q tok-rotated "${SK}/plugin-config-data/signalk-to-influxdb2.json" &&
    ok "  influx token is refreshed" ||
    bad "  influx token is refreshed" "$(cat "${SK}/plugin-config-data/signalk-to-influxdb2.json")"
grep -q "chown root:root ${DATA}/admin-password" "${STUB_LOG}" &&
    ok "  admin-password goes back to root" || bad "  admin-password goes back to root" "$(cat "${STUB_LOG}")"
grep -q "chown root:root ${DATA}/oidc-secret" "${STUB_LOG}" &&
    ok "  oidc-secret goes back to root" || bad "  oidc-secret goes back to root" "$(cat "${STUB_LOG}")"
teardown

# The hook is sourced by the generated prestart, so a false test at the end of it
# would become the whole unit's exit status.
setup
: > "${DATA}/admin-password"
check "absent oidc-secret still exits 0" "$(run_hook)" "0"
teardown

printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
