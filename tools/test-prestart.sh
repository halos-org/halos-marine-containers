#!/bin/bash
# Exercise apps/signalk-server/prestart.sh with stubbed chown/bcrypt.
#
# The hook writes three files holding secrets. Their modes are a property of the
# filesystem after it runs, not of the script's text, so this runs it against a
# sandbox: no root, no container, no InfluxDB.
#
# Modes are asserted against the real filesystem. Ownership is asserted against
# the chown stub's call log -- the run is unprivileged, so no uid here can ever
# be the container's. That log records what the hook asked for, not what the
# kernel did, which is the ceiling for this harness; the handover itself is only
# confirmable by installing a plugin through the app store on a real device.
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

    # Fails on a path that is neither a file nor a symlink, the way the real
    # chown does. A stub that always succeeds cannot see a chown on a path the
    # hook forgot to guard -- and under set -e that is an ExecStartPre abort,
    # not a warning.
    cat > "${SANDBOX}/bin/chown" <<'STUB'
#!/bin/bash
echo "chown $*" >> "${STUB_LOG}"
for arg in "$@"; do
    case "$arg" in
        -*|*:*) continue ;;
    esac
    [ -e "$arg" ] || [ -L "$arg" ] || {
        echo "chown: cannot access '$arg': No such file or directory" >&2
        exit 1
    }
done
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

# Sourced under set -e, matching how the generated framework prestart runs this
# (container-packaging-tools prestart.py: `set -e`, then the hook as a statement
# so a failure inside it propagates). Running it as a plain `bash "${HOOK}"`
# would report only the last command's status, so any command that aborts the
# real ExecStartPre -- and takes the navigation server down with it -- would look
# like a clean exit 0 here.
run_hook() {  # echoes exit status
    PATH="${SANDBOX}/bin:${PATH}" \
        CONTAINER_DATA_ROOT="${DATA}" \
        RUNTIME_ENV="${SANDBOX}/runtime.env" \
        HALOS_DOMAIN="test.local" \
        INFLUXDB_ENV="${SANDBOX}/influxdb.env" \
        bash -c 'set -e; . "$1"' _ "${HOOK}" > "${SANDBOX}/out" 2>&1
    echo $?
}

influx_available() {  # $1 = token to publish
    printf 'INFLUXDB_ADMIN_TOKEN=%s\n' "$1" > "${SANDBOX}/influxdb.env"
}

# Matches the whole call, not just the path. Asserting only that the path was
# named passes `chown -h 0:0` and passes a chown that dropped -h -- both leave the
# device exactly as broken as the missing chown this guard exists to catch, so
# the owner and the -h have to be in the same log line as the path.
#
# -h matters here specifically: signalk-halpi's postinst and the pi-gen stage
# both create symlinks inside node_modules, and the directory is container-
# writable, so a dereferencing chown would let the container pick which host path
# root hands over.
#
# Exact field match, not a substring: "${SK}/node_modules" is a prefix of every
# path below it, so a grep would report the tree as handed over when only a child
# was -- or the reverse.
chowned() {  # $1 = path the hook must have handed to the container uid
    awk -v p="$1" '
        BEGIN { f = 1 }
        {
            owner = 0; noderef = 0; path = 0
            for (i = 1; i <= NF; i++) {
                if ($i == "1000:1000") owner = 1
                else if ($i ~ /^-[A-Za-z]*h/) noderef = 1
                else if ($i == p) path = 1
            }
            if (owner && noderef && path) f = 0
        }
        END { exit f }' "${STUB_LOG}"
}

echo "prestart.sh behaviour"

setup
check "fresh install exits 0" "$(run_hook)" "0"
check "  security.json is 0600" "$(mode "${SK}/security.json")" "600"
chowned "${SK}/security.json" &&
    ok "  security.json handed over with -h" ||
    bad "  security.json handed over with -h" "$(cat "${STUB_LOG}")"
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

# signalk-halpi's postinst creates both paths as root before Signal K has ever
# run, and left that way every app-store plugin install fails EACCES --
# permanently, and only visibly in the admin UI. Modelled with the symlink it
# really plants inside node_modules, which is what makes -h and the
# non-recursive chown load-bearing rather than stylistic.
setup
mkdir -p "${SK}/node_modules" "${SK}/system-plugins/signalk-halpi"
ln -s ../system-plugins/signalk-halpi "${SK}/node_modules/signalk-halpi"
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

# uid 1000 owns ${SIGNALK_DATA} -- this hook hands it over -- so the container can
# replace node_modules with a symlink. Dangling, mkdir -p does not create through
# it, it exits 1; sourced under the framework's set -e that fails ExecStartPre on
# every boot with nothing to clear it, and the navigation server never starts.
setup
ln -s /nonexistent/relocated "${SK}/node_modules"
check "a dangling node_modules symlink does not wedge the unit" "$(run_hook)" "0"
[ -d "${SK}/node_modules" ] && [ ! -L "${SK}/node_modules" ] &&
    ok "  it is replaced by a real directory" ||
    bad "  it is replaced by a real directory" "still $(ls -ld "${SK}/node_modules")"
teardown

# A symlink to a directory that exists is someone relocating the plugin tree to
# another disk, not an attack. mkdir -p accepts it, and chown -h must hand over
# the link rather than whatever it points at -- following it would let the
# container choose which host path root gives away.
setup
mkdir -p "${SANDBOX}/elsewhere"
ln -s "${SANDBOX}/elsewhere" "${SK}/node_modules"
check "a relocated node_modules is left in place" "$(run_hook)" "0"
[ -L "${SK}/node_modules" ] &&
    ok "  the symlink survives" || bad "  the symlink survives" "symlink was replaced"
teardown

# The one path in this hook that deliberately takes the unit down. If the symlink
# cannot be removed, writing through it is worse than not starting -- but that
# tradeoff is only defensible if it actually happens, so pin it.
setup
ln -s /nonexistent "${SK}/security.json"
cat > "${SANDBOX}/bin/rm" <<'STUB'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in */security.json) echo "rm: cannot remove" >&2; exit 1 ;; esac
done
exec /bin/rm "$@"
STUB
chmod 755 "${SANDBOX}/bin/rm"
st=$(run_hook)
[ "$st" != "0" ] &&
    ok "an unremovable symlink withholds the app rather than writing through" ||
    bad "an unremovable symlink withholds the app rather than writing through" "exit 0"
grep -q 'refusing to write through it' "${SANDBOX}/out" &&
    ok "  and says why" || bad "  and says why" "$(cat "${SANDBOX}/out")"
teardown

# A full data partition is the realistic trigger: mkdir needs a block, the chmods
# on existing files above do not. Signal K must still come up -- plugin updates
# broken beats a navigation server that never starts -- so the failure is a
# warning, and nothing after it may abort under the framework's set -e.
setup
cat > "${SANDBOX}/bin/mkdir" <<'STUB'
#!/bin/bash
for arg in "$@"; do
    case "$arg" in */node_modules) echo "mkdir: no space left on device" >&2; exit 1 ;; esac
done
exec /bin/mkdir "$@"
STUB
chmod 755 "${SANDBOX}/bin/mkdir"
check "an unwritable node_modules warns instead of blocking start" "$(run_hook)" "0"
grep -q "WARNING: could not create" "${SANDBOX}/out" &&
    ok "  and says so" || bad "  and says so" "$(cat "${SANDBOX}/out")"
teardown

# The container owns ${SIGNALK_DATA}, so it can replace any file root writes
# there with a symlink and redirect the write. chmod, touch and cat > all
# dereference. The canary lives outside the data root: if the hook writes
# through the link, the canary changes, and that is a container-to-host-root
# escalation on a real device.
setup
CANARY="${SANDBOX}/outside-the-data-root"
printf 'original\n' > "${CANARY}"; chmod 644 "${CANARY}"
ln -s "${CANARY}" "${SK}/security.json"
check "a symlinked security.json does not wedge the unit" "$(run_hook)" "0"
[ "$(cat "${CANARY}")" = "original" ] &&
    ok "  the link target is not written through" ||
    bad "  the link target is not written through" "$(cat "${CANARY}")"
check "  the link target keeps its mode" "$(mode "${CANARY}")" "644"
[ -f "${SK}/security.json" ] && [ ! -L "${SK}/security.json" ] &&
    ok "  a real security.json replaces the link" ||
    bad "  a real security.json replaces the link" "$(ls -ld "${SK}/security.json")"
check "  and is 0600" "$(mode "${SK}/security.json")" "600"
grep -q 'removing unexpected symlink' "${SANDBOX}/out" &&
    ok "  the removal is logged" || bad "  the removal is logged" "$(cat "${SANDBOX}/out")"
teardown

# The full escalation needs a DANGLING link. A link to an existing file satisfies
# [ -f ], so the hook takes its "already exists" branch and only strips the mode;
# a link to a path that does not exist takes the create branch, where touch
# creates the target, cat > writes the admin hash and JWT key into it, and chown
# hands it to uid 1000. That is the /etc/ld.so.preload chain, and the assertion
# that matters is that the target path is never created at all.
setup
TARGET="${SANDBOX}/does-not-exist-yet"
ln -s "${TARGET}" "${SK}/security.json"
check "a dangling security.json link does not wedge the unit" "$(run_hook)" "0"
[ ! -e "${TARGET}" ] &&
    ok "  root never creates the link target" ||
    bad "  root never creates the link target" "created: $(ls -l "${TARGET}"; cat "${TARGET}")"
[ -f "${SK}/security.json" ] && [ ! -L "${SK}/security.json" ] &&
    ok "  a real security.json is created instead" ||
    bad "  a real security.json is created instead" "$(ls -ld "${SK}/security.json")"
grep -q secretKey "${SK}/security.json" &&
    ok "  with the generated secrets in it" ||
    bad "  with the generated secrets in it" "$(cat "${SK}/security.json")"
teardown

# Same attack against the InfluxDB token config, whose parent is equally
# container-writable. The token is the InfluxDB admin credential.
setup
CANARY="${SANDBOX}/outside-the-data-root"
printf 'original\n' > "${CANARY}"; chmod 644 "${CANARY}"
mkdir -p "${SK}/plugin-config-data"
ln -s "${CANARY}" "${SK}/plugin-config-data/signalk-to-influxdb2.json"
influx_available tok-symlink
check "a symlinked influx config does not wedge the unit" "$(run_hook)" "0"
[ "$(cat "${CANARY}")" = "original" ] &&
    ok "  no token written through the link" ||
    bad "  no token written through the link" "$(cat "${CANARY}")"
check "  the link target keeps its mode" "$(mode "${CANARY}")" "644"
check "  a real config replaces the link, 0600" \
    "$(mode "${SK}/plugin-config-data/signalk-to-influxdb2.json")" "600"
teardown

# The token-rewrite branch writes a sibling temp file, and plugin-config-data is
# chowned to uid 1000 on every run -- so the container can plant the .tmp path as
# a symlink and redirect root's write through a path the guard never names. Needs
# an existing config so the run takes the update branch rather than the create.
setup
CANARY="${SANDBOX}/outside-the-data-root"
printf 'original\n' > "${CANARY}"; chmod 644 "${CANARY}"
mkdir -p "${SK}/plugin-config-data"
printf '{"configuration":{"influxes":[{"token":"stale"}]}}\n' \
    > "${SK}/plugin-config-data/signalk-to-influxdb2.json"
ln -s "${CANARY}" "${SK}/plugin-config-data/signalk-to-influxdb2.json.tmp"
influx_available tok-tmplink
check "a symlinked .tmp does not redirect the token rewrite" "$(run_hook)" "0"
[ "$(cat "${CANARY}")" = "original" ] &&
    ok "  the link target is not written through" ||
    bad "  the link target is not written through" "$(cat "${CANARY}")"
check "  the link target keeps its mode" "$(mode "${CANARY}")" "644"
grep -q tok-tmplink "${SK}/plugin-config-data/signalk-to-influxdb2.json" &&
    ok "  and the real config still gets the token" ||
    bad "  and the real config still gets the token" "$(cat "${SK}/plugin-config-data/signalk-to-influxdb2.json")"
teardown

# A symlinked plugin-config-data directory redirects everything below it, so the
# parent has to be cleared before the child path is even resolved.
setup
OUTSIDE="${SANDBOX}/outside-dir"
mkdir -p "${OUTSIDE}"
ln -s "${OUTSIDE}" "${SK}/plugin-config-data"
influx_available tok-dirlink
check "a symlinked plugin-config-data does not wedge the unit" "$(run_hook)" "0"
[ ! -e "${OUTSIDE}/signalk-to-influxdb2.json" ] &&
    ok "  nothing written into the link target" ||
    bad "  nothing written into the link target" "$(ls -l "${OUTSIDE}")"
[ -d "${SK}/plugin-config-data" ] && [ ! -L "${SK}/plugin-config-data" ] &&
    ok "  a real directory replaces the link" ||
    bad "  a real directory replaces the link" "$(ls -ld "${SK}/plugin-config-data")"
teardown

# apps/influxdb/prestart.sh has paths that leave the env file without a usable
# token. With the plugin-presence gate gone, the emptiness check is the only
# thing standing between that and a config naming the database with no
# credential.
setup
printf 'INFLUXDB_ADMIN_TOKEN=\n' > "${SANDBOX}/influxdb.env"
check "no influx config when the env file carries no token" "$(run_hook)" "0"
[ ! -e "${SK}/plugin-config-data/signalk-to-influxdb2.json" ] &&
    ok "  config is absent" ||
    bad "  config is absent" "$(cat "${SK}/plugin-config-data/signalk-to-influxdb2.json")"
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
