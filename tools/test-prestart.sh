#!/bin/bash
# Exercise apps/signalk-server/prestart.sh with stubbed chown/bcrypt.
#
# The hook writes three files holding secrets. Their modes are a property of the
# filesystem after it runs, not of the script's text, so this runs it against a
# sandbox: no root, no container, no InfluxDB.
#
# Ownership is NOT covered: the run is unprivileged, so chown is stubbed out and
# nothing here can observe a uid. Assert modes, not owners.
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
    printf 'INFLUXDB_ADMIN_TOKEN=%s\n' "$1" > "${SANDBOX}/influxdb.env"
}

# Exact field match, not a substring: "${SK}/node_modules" is a prefix of every
# path below it, so a grep would report the tree as handed over when only a child
# was -- or the reverse.
chowned() {  # $1 = path the hook must have handed to the container uid
    awk -v p="$1" 'BEGIN{f=1} {for (i=1; i<=NF; i++) if ($i == p) f=0} END{exit f}' \
        "${STUB_LOG}"
}

echo "prestart.sh behaviour"

setup
check "fresh install exits 0" "$(run_hook)" "0"
check "  security.json is 0600" "$(mode "${SK}/security.json")" "600"
check "  admin-password is 0600" "$(mode "${DATA}/admin-password")" "600"
teardown

# The plugin is baked into the image, so the data volume holds no evidence of it.
# A hook that gates on finding it under ${SK}/node_modules writes nothing here,
# which is what every fresh device looks like -- the server starts and only the
# graphs stay empty. This sandbox has no node_modules at all, deliberately.
setup
influx_available tok-fresh
check "influx config is written with no node_modules present" "$(run_hook)" "0"
check "  at 0600" "$(mode "${SK}/plugin-config-data/signalk-to-influxdb2.json")" "600"
grep -q tok-fresh "${SK}/plugin-config-data/signalk-to-influxdb2.json" &&
    ok "  with the token" || bad "  with the token" "token missing from config"
teardown

# The other half of that condition has to survive: without InfluxDB installed
# there is no token to write, and a config naming an absent database is worse
# than none.
setup
check "no influx config without the InfluxDB env file" "$(run_hook)" "0"
[ ! -e "${SK}/plugin-config-data/signalk-to-influxdb2.json" ] &&
    ok "  config is absent" ||
    bad "  config is absent" "$(cat "${SK}/plugin-config-data/signalk-to-influxdb2.json")"
teardown

# provision.sh used to own this. signalk-halpi's postinst creates both paths as
# root before Signal K has ever run, and left that way every app-store plugin
# install fails EACCES -- permanently, and only visibly in the admin UI.
setup
mkdir -p "${SK}/node_modules"
printf '{"dependencies":{"signalk-halpi":"file:system-plugins/signalk-halpi"}}\n' \
    > "${SK}/package.json"
check "a root-created node_modules is handed over" "$(run_hook)" "0"
chowned "${SK}/node_modules" &&
    ok "  node_modules" || bad "  node_modules" "$(cat "${STUB_LOG}")"
chowned "${SK}/package.json" &&
    ok "  package.json" || bad "  package.json" "$(cat "${STUB_LOG}")"
teardown

# A device that never installed signalk-halpi has no node_modules until the app
# store writes one -- as uid 1000 inside the container, which cannot create it if
# the parent is root-owned at that moment. Create it here instead.
setup
check "a missing node_modules is created" "$(run_hook)" "0"
[ -d "${SK}/node_modules" ] &&
    ok "  it exists" || bad "  it exists" "node_modules was not created"
chowned "${SK}/node_modules" &&
    ok "  and is handed over" || bad "  and is handed over" "$(cat "${STUB_LOG}")"
teardown

# What an upgraded device looks like: the secret files the old hook wrote 0644.
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
teardown

# The hook is sourced by the generated prestart, so a false test at the end of it
# would become the whole unit's exit status.
setup
: > "${DATA}/admin-password"
check "a partially-populated data root still exits 0" "$(run_hook)" "0"
teardown

printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
