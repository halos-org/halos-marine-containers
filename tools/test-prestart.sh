#!/bin/bash
# Exercise apps/signalk-server/prestart.sh with chown stubbed.
#
# The hook writes three files holding secrets. Their modes are a property of the
# filesystem after it runs, not of the script's text, so this runs it against a
# sandbox: no container, no InfluxDB, and deliberately not as root -- see the
# refusal below.
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

# Several scenarios stage their condition with chmod 555, which root ignores.
# Run as root the suite is neither green nor usefully red: two of them fail with
# nothing pointing at the environment, and one passes without exercising the
# failure it names. Refuse rather than report either.
if [ "$(id -u)" = "0" ]; then
    echo "tools/test-prestart.sh must not run as root: the scenarios staged with" >&2
    echo "chmod 555 cannot be staged against a caller that ignores file modes." >&2
    exit 1
fi
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

# The pipeline as the file spells it, in order. Asserting on the whole sequence
# rather than grepping for "providers/liner": a liner spliced at the wrong index
# leaves the grep green and the connection just as broken.
#
# Failures print ERROR rather than going to /dev/null. Swallowing them makes a
# missing or unparseable file indistinguishable from an empty pipeline, so an
# expectation that was ever empty would pass against a hook that deleted the file.
element_types() {  # $1 = a settings.json, $2 = index into pipedProviders (default 0)
    "${REAL_PYTHON3}" -c '
import json, sys
try:
    settings = json.load(open(sys.argv[1]))
    provider = settings["pipedProviders"][int(sys.argv[2])]
    print(" ".join(e.get("type", "?") for e in provider["pipeElements"]))
except Exception as exc:
    print("ERROR: %s" % exc)
' "$1" "${2:-0}"
}

# The migration round-trips the whole document through json.loads/json.dumps, and
# the element-type assertions above only look at one provider's pipeline. A
# rewrite that dropped the vessel uuid, the mmsi or the interfaces settings would
# pass every one of them, so this compares everything else against the copy the
# hook kept: remove the liners from the migrated file and it must equal it.
migration_changed_nothing_else() {  # $1 = migrated settings.json, $2 = the backup
    "${REAL_PYTHON3}" -c '
import json, sys
migrated = json.load(open(sys.argv[1]))
before = json.load(open(sys.argv[2]))
for provider in migrated.get("pipedProviders", []):
    provider["pipeElements"] = [e for e in provider["pipeElements"]
                                if e.get("type") != "providers/liner"]
sys.exit(0 if migrated == before else 1)
' "$1" "$2"
}

# What every device seeded from v0.3.1+13 onward carries: gpsd piped straight
# into the parser. gpsd writes a whole NMEA reporting cycle in one TCP write, so
# with no splitter between them the parser rejects every burst and no position
# ever reaches Signal K.
PRE_LINER_SETTINGS='{
  "ssl": false,
  "trustProxy": true,
  "pipedProviders": [
    {
      "id": "gpsd",
      "pipeElements": [
        {
          "type": "providers/gpsd",
          "options": {
            "hostname": "localhost",
            "port": 2947,
            "noDataReceivedTimeout": 30,
            "reconnectInterval": 15
          }
        },
        {
          "type": "providers/nmea0183-signalk"
        }
      ],
      "enabled": true
    }
  ]
}'

setup() {
    SANDBOX="$(mktemp -d)"
    DATA="${SANDBOX}/data"
    SK="${DATA}/data"
    mkdir -p "${SK}" "${SANDBOX}/bin" "${SANDBOX}/pylib"
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
    # python3 is passed straight through. bcrypt is deliberately not stubbed:
    # the python block that imports it is the thing under test, so intercepting
    # it would gut the suite. It is a declared package dependency
    # (python3-bcrypt); install it locally to run this.
    cat > "${SANDBOX}/bin/python3" <<'STUB'
#!/bin/bash
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
#
# Under a timeout, because the failure this suite exists to catch can hang rather
# than fail: opening a FIFO to read blocks until a writer appears, so a hook that
# leaves one in place stops here forever instead of reporting anything. A hang is
# an ExecStartPre that never returns, which is a failure and should read as one.
TIMEOUT="$(command -v timeout || command -v gtimeout || true)"
run_hook() {  # echoes exit status
    PATH="${SANDBOX}/bin:${PATH}" \
        CONTAINER_DATA_ROOT="${DATA}" \
        RUNTIME_ENV="${SANDBOX}/runtime.env" \
        HALOS_DOMAIN="test.local" \
        INFLUXDB_ENV="${SANDBOX}/influxdb.env" \
        QUESTDB_COMPOSE="${SANDBOX}/questdb-compose.yml" \
        PYTHONPATH="${SANDBOX}/pylib" \
        ${TIMEOUT:+"${TIMEOUT}" -s KILL 20} \
        bash -c 'set -e; . "$1"' _ "${HOOK}" > "${SANDBOX}/out" 2>&1
    echo $?
}

influx_available() {  # $1 = token to publish
    printf 'INFLUXDB_ADMIN_TOKEN=%s\n' "$1" > "${SANDBOX}/influxdb.env"
}

questdb_available() {  # the app's compose file is the signal; see the hook
    : > "${SANDBOX}/questdb-compose.yml"
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

# Plants a hostile object at the instant before the hook opens a path, which is
# the window every guard here exists for. A bcrypt shim used to serve this and
# cannot any more: the clear happens inside the create, after the hash, so
# anything planted from bcrypt lands *before* the clear and is simply removed --
# which is how the two racer scenarios silently became no-ops. Wrapping os.open
# is inside the window by construction, and stays there if the order changes.
inject_before_open() {  # $1 = True for the create, False for the read; $2 = sh;
                        # $3 = the name to fire on (default security.json)
    cat > "${SANDBOX}/pylib/sitecustomize.py" <<SHIM
import os, subprocess
_real, _fired = os.open, []
def _open(path, flags, mode=0o777, *, dir_fd=None):
    if path == "${3:-security.json}" and not _fired and bool(flags & os.O_CREAT) is ${1}:
        _fired.append(True)
        subprocess.run(["sh", "-c", r"""${2}"""])
    return _real(path, flags, mode, dir_fd=dir_fd)
os.open = _open
SHIM
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

# QuestDB's config is gated on the app being installed, unlike InfluxDB's. There
# is no token to inject here, so nothing forces an unconditional write -- and a
# config naming a database that is not there makes the plugin report an error
# on a device that simply chose not to install it.
setup
questdb_available
check "questdb config is written when the app is installed" "$(run_hook)" "0"
QDB_CFG="${SK}/plugin-config-data/signalk-questdb-history-provider.json"
check "  at 0600" "$(mode "${QDB_CFG}")" "600"
python3 - "${QDB_CFG}" <<'EOF' && ok "  loopback, no managed container, no promotion flag" ||
import json, sys
c = json.load(open(sys.argv[1]))
cfg = c["configuration"]
assert c["enabled"] is True, c
assert cfg["questdbHost"] == "127.0.0.1", cfg
# The plugin dropped this setting in 2.0.0 and its schema no longer defines
# it, so writing it would seed every new device with a dead key.
assert "managedContainer" not in cfg, cfg
# The plugin cannot promote itself: the route is admin-authenticated and it
# calls its own server with no credentials, so arming this only buys a 401 in
# the log on every boot. settings.json carries the default instead.
assert "promoteToDefaultProvider" not in cfg, cfg
EOF
    bad "  loopback, no managed container, no promotion flag" "$(cat "${QDB_CFG}")"
teardown

setup
check "no questdb config without the app installed" "$(run_hook)" "0"
[ ! -e "${SK}/plugin-config-data/signalk-questdb-history-provider.json" ] &&
    ok "  config is absent" ||
    bad "  config is absent" "$(cat "${SK}/plugin-config-data/signalk-questdb-history-provider.json")"
teardown

# Write once, never rewrite. InfluxDB's config is rewritten every boot because a
# rotating token has to reach it; this one carries no secret, so rewriting would
# only ever discard what the operator changed -- path filters, sampling rates,
# retention -- on the next restart.
setup
questdb_available
run_hook > /dev/null
QDB_CFG="${SK}/plugin-config-data/signalk-questdb-history-provider.json"
python3 - "${QDB_CFG}" <<'EOF'
import json, sys
c = json.load(open(sys.argv[1]))
c["configuration"]["retentionDays"] = 30
c["configuration"]["questdbHost"] = "192.168.1.50"
json.dump(c, open(sys.argv[1], "w"))
EOF
check "an edited questdb config survives the next boot" "$(run_hook)" "0"
python3 - "${QDB_CFG}" <<'EOF' && ok "  operator edits are intact" ||
import json, sys
cfg = json.load(open(sys.argv[1]))["configuration"]
assert cfg["retentionDays"] == 30, cfg
assert cfg["questdbHost"] == "192.168.1.50", cfg
EOF
    bad "  operator edits are intact" "$(cat "${QDB_CFG}")"
teardown

# The default history provider. Installing the QuestDB app must not take the
# slot from whatever already serves history on that device, so the hook only
# clears a key naming an app that is gone. settings.json is the only place the
# server takes this from; the plugin's own route for it is admin-authenticated.
SETTINGS='{"interfaces":{"nmea-tcp":false},"vessel":{"uuid":"urn:mrn:signalk:uuid:test"}}'
default_provider() {  # echoes the configured id, or the empty string
    python3 -c 'import json,sys; print((json.load(open(sys.argv[1])).get("historyApi") or {}).get("defaultProvider",""))' "$1"
}

setup
questdb_available
printf '%s\n' "${SETTINGS}" > "${SK}/settings.json"
chmod 644 "${SK}/settings.json"
check "installing questdb does not claim the default" "$(run_hook)" "0"
check "  no default is named" "$(default_provider "${SK}/settings.json")" ""
check "  the file keeps its mode" "$(mode "${SK}/settings.json")" "644"
python3 - "${SK}/settings.json" <<'EOF' && ok "  the document is untouched" ||
import json, sys
s = json.load(open(sys.argv[1]))
assert s["vessel"]["uuid"] == "urn:mrn:signalk:uuid:test", s
assert s["interfaces"] == {"nmea-tcp": False}, s
assert "historyApi" not in s, s
EOF
    bad "  the document is untouched" "$(cat "${SK}/settings.json")"
teardown

# An operator who chose QuestDB keeps it for as long as the app is there.
setup
questdb_available
printf '%s\n' '{"historyApi":{"defaultProvider":"signalk-questdb-history-provider"}}' > "${SK}/settings.json"
check "a chosen questdb default survives a start" "$(run_hook)" "0"
check "  still QuestDB" \
    "$(default_provider "${SK}/settings.json")" "signalk-questdb-history-provider"
teardown

# An operator who chose InfluxDB keeps it, QuestDB app or no QuestDB app.
setup
questdb_available
printf '%s\n' '{"historyApi":{"defaultProvider":"signalk-to-influxdb2"}}' > "${SK}/settings.json"
check "another provider is left alone with questdb installed" "$(run_hook)" "0"
check "  still InfluxDB" \
    "$(default_provider "${SK}/settings.json")" "signalk-to-influxdb2"
teardown

# Nothing here knows what a non-object historyApi was meant to be, and replacing
# it would discard whatever it held.
setup
questdb_available
printf '%s\n' '{"historyApi":"nonsense"}' > "${SK}/settings.json"
check "a malformed historyApi does not block the start" "$(run_hook)" "0"
check "  and is left as it was" \
    "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["historyApi"])' "${SK}/settings.json")" \
    "nonsense"
teardown

setup
printf '%s\n' "${SETTINGS}" > "${SK}/settings.json"
check "no default history provider without the questdb app" "$(run_hook)" "0"
check "  settings name none" "$(default_provider "${SK}/settings.json")" ""
teardown

# Removing the app has to take the key with it. A configured provider that
# never registers is not silent: the first history request after that raises a
# warn notification at notifications.server.history.defaultProvider, and the
# server clears it only when that provider registers again -- never, for an app
# that is gone. So it is a standing alarm on the vessel, not a fallback.
setup
printf '%s\n' '{"historyApi":{"defaultProvider":"signalk-questdb-history-provider"},"vessel":{"uuid":"x"}}' \
    > "${SK}/settings.json"
check "removing the questdb app clears the default" "$(run_hook)" "0"
check "  the key is gone" "$(default_provider "${SK}/settings.json")" ""
python3 - "${SK}/settings.json" <<'EOF' && ok "  historyApi survives, and so does the rest" ||
import json, sys
s = json.load(open(sys.argv[1]))
assert "defaultProvider" not in s["historyApi"], s
assert s["vessel"]["uuid"] == "x", s
EOF
    bad "  historyApi survives, and so does the rest" "$(cat "${SK}/settings.json")"
teardown

# Exact match only. Whatever else the operator chose is theirs, and the app
# being absent says nothing about whether they still want it.
setup
printf '%s\n' '{"historyApi":{"defaultProvider":"signalk-to-influxdb2"}}' > "${SK}/settings.json"
check "removing questdb leaves another provider alone" "$(run_hook)" "0"
check "  still InfluxDB" \
    "$(default_provider "${SK}/settings.json")" "signalk-to-influxdb2"
teardown

# A fresh install has no settings.json until the postinst seeds default-data, and
# the hook runs before that on the very first start. Writing a partial file here
# would lose every default the seed carries, so it does nothing and the next boot
# picks it up.
setup
questdb_available
check "a missing settings.json is not created" "$(run_hook)" "0"
[ ! -e "${SK}/settings.json" ] &&
    ok "  settings.json is still absent" ||
    bad "  settings.json is still absent" "$(cat "${SK}/settings.json")"
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

# A plain directory at a guarded path was a race-free boot wedge: the old guard
# only fired on [ -L ], so cat > failed "Is a directory" on every single boot and
# five of those put the unit in `failed`. One mkdir from uid 1000 was enough.
setup
mkdir -p "${SK}/security.json"
check "a directory at security.json does not wedge the unit" "$(run_hook)" "0"
[ -f "${SK}/security.json" ] && [ ! -d "${SK}/security.json" ] &&
    ok "  a real security.json is created" ||
    bad "  a real security.json is created" "$(ls -ld "${SK}/security.json")"
[ -d "${SK}/security.json.unexpected" ] &&
    ok "  the directory is moved aside, not deleted" ||
    bad "  the directory is moved aside, not deleted" "no .unexpected directory"
teardown

# A FIFO is the case bash's noclobber silently followed: with a reader attached
# the old hook logged "Security initialized", wrote nothing to disk, and streamed
# the admin hash and JWT signing key to whoever held the read end.
setup
mkfifo "${SK}/security.json"
( timeout 10 cat "${SK}/security.json" > "${SANDBOX}/leak" 2>/dev/null & )
check "a FIFO at security.json does not leak the secrets" "$(run_hook)" "0"
sleep 0.3
[ ! -s "${SANDBOX}/leak" ] &&
    ok "  nothing was streamed to the reader" ||
    bad "  nothing was streamed to the reader" "$(head -c 120 "${SANDBOX}/leak")"
[ -f "${SK}/security.json" ] && [ ! -p "${SK}/security.json" ] &&
    ok "  a real security.json replaces it" ||
    bad "  a real security.json replaces it" "$(ls -ld "${SK}/security.json")"
grep -q secretKey "${SK}/security.json" 2>/dev/null &&
    ok "  with the secrets on disk where they belong" ||
    bad "  with the secrets on disk where they belong" "$(cat "${SK}/security.json" 2>&1)"
teardown

# Everything above plants its hostile object BEFORE the hook runs, where the type
# check clears it -- so none of it exercises O_EXCL. These plant in the window
# between the clear and the create, which is the only condition O_EXCL exists for.
#
# The status is asserted, not discarded. O_EXCL refusing the write and python
# dying before it reaches the write leave a canary equally untouched, so a test
# that only reads the canary cannot tell a working guard from a crash -- and the
# crash is itself an ExecStartPre abort the racer can repeat until systemd gives
# up on the unit.
setup
CANARY="${SANDBOX}/outside-the-data-root"
printf 'original\n' > "${CANARY}"; chmod 644 "${CANARY}"
inject_before_open True "ln -sfn '${CANARY}' '${SK}/security.json'"
check "a symlink planted after the clear does not wedge the unit" "$(run_hook)" "0"
[ "$(cat "${CANARY}")" = "original" ] &&
    ok "  the link target is not written through" ||
    bad "  the link target is not written through" "$(cat "${CANARY}")"
check "  and the link target keeps its mode" "$(mode "${CANARY}")" "644"
[ -f "${SK}/security.json" ] && [ ! -L "${SK}/security.json" ] &&
    ok "  a real security.json is created instead" ||
    bad "  a real security.json is created instead" "$(ls -ld "${SK}/security.json" 2>&1)"
teardown

# A symlink is refused by O_EXCL and by O_NOFOLLOW alike, so the scenario above
# pins neither on its own. A FIFO is not a symlink: O_NOFOLLOW lets it through
# and only O_EXCL refuses it. This is the scenario that pins O_EXCL by itself.
#
# The assertion is the post-state, not a reader's capture: uid 1000 is meant to
# read security.json once it is handed over, so "a reader saw bytes" is true in
# the healthy case too. What a FIFO costs is the file -- the write goes into the
# pipe, or blocks with no reader, and security.json is never created.
setup
inject_before_open True "rm -f '${SK}/security.json'; mkfifo '${SK}/security.json'"
check "a FIFO planted after the clear does not wedge the unit" "$(run_hook)" "0"
[ -f "${SK}/security.json" ] && [ ! -p "${SK}/security.json" ] &&
    ok "  a real security.json is created, not written into the pipe" ||
    bad "  a real security.json is created, not written into the pipe" \
        "$(ls -ld "${SK}/security.json" 2>&1)"
# Guarded on -f: if the hook left the FIFO in place, this grep would open it for
# reading and block until a writer appears, hanging the suite instead of failing
# the assertion above it.
[ -f "${SK}/security.json" ] && grep -q secretKey "${SK}/security.json" 2>/dev/null &&
    ok "  with the secrets in it" ||
    bad "  with the secrets in it" "$(ls -ld "${SK}/security.json" 2>&1)"
teardown

# The same window on the read side. converge_mode opens an existing security.json
# to tighten its mode, and O_NOFOLLOW does not refuse a FIFO -- an O_RDONLY open
# of one blocks until a writer appears, which for ExecStartPre means hanging
# until TimeoutStartSec on every boot the racer chooses.
setup
printf '{"users":[]}\n' > "${SK}/security.json"
inject_before_open False "rm -f '${SK}/security.json'; mkfifo '${SK}/security.json'"
check "a FIFO planted before the mode check does not hang the boot" "$(run_hook)" "0"
[ -f "${SK}/security.json" ] && [ ! -p "${SK}/security.json" ] &&
    ok "  and a real security.json replaces it" ||
    bad "  and a real security.json replaces it" "$(ls -ld "${SK}/security.json" 2>&1)"
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
grep -q 'unexpected symlink at' "${SANDBOX}/out" &&
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
# Valid JSON on purpose. With plain text the hook's json.load raises before it
# writes anything, so "not written through" would pass against a vulnerable hook
# for a reason that has nothing to do with the guard.
printf '{"configuration":{"influxes":[{"token":"none"}]}}\n' > "${CANARY}"
chmod 644 "${CANARY}"
mkdir -p "${SK}/plugin-config-data"
ln -s "${CANARY}" "${SK}/plugin-config-data/signalk-to-influxdb2.json"
influx_available tok-symlink
check "a symlinked influx config does not wedge the unit" "$(run_hook)" "0"
grep -q tok-symlink "${CANARY}" &&
    bad "  no token written through the link" "token landed in the link target" ||
    ok "  no token written through the link"
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

# Refusing to start is the right answer when the path cannot be made safe, so the
# cases below are not about softening that. They are about the abort firing when
# nothing is actually wrong -- an abort the container can trigger on demand, or a
# disk fault that redirects nothing, is a permanent outage bought for nothing.
# ExecStartPre has no restart budget to spare: five failures and the unit is
# `failed` until someone reaches the boat.

# The move-aside picks a fixed name, so occupying that name makes the clear fail
# and the hook refuse to start -- on every boot, from two commands. It also
# happens with no attacker: run N moves a directory aside, run N+1 finds another
# one and collides with its own leftover.
setup
mkdir -p "${SK}/security.json"
: > "${SK}/security.json.unexpected"
check "an occupied .unexpected name does not wedge the unit" "$(run_hook)" "0"
[ -f "${SK}/security.json" ] && [ ! -d "${SK}/security.json" ] &&
    ok "  a real security.json replaces the directory" ||
    bad "  a real security.json replaces the directory" "$(ls -ld "${SK}/security.json" 2>&1)"
teardown

# The InfluxDB section documents itself as warn-only. uid 1000 owns this file --
# the hook hands it over on every run -- and any valid JSON that is not an object
# makes .get() raise, which `except (OSError, ValueError)` does not catch.
for payload in '[]' 'null' '42' '"str"'; do
    setup
    influx_available "tok-abc"
    mkdir -p "${SK}/plugin-config-data"
    printf '%s' "${payload}" > "${SK}/plugin-config-data/signalk-to-influxdb2.json"
    check "an influx config of ${payload} warns instead of blocking start" "$(run_hook)" "0"
    teardown
done

# admin-password is the documented way back in when OIDC is what broke. It is
# written after security.json, and the password exists only in memory in between,
# so a failure there loses it for the life of the device: every later boot sees
# security.json and skips the whole create branch.
setup
chmod 555 "${DATA}"
run_hook > /dev/null 2>&1
chmod 755 "${DATA}"
check "a failed admin-password write leaves nothing half-created" "$(run_hook)" "0"
[ -s "${DATA}/admin-password" ] &&
    ok "  the emergency password is written on the retry" ||
    bad "  the emergency password is written on the retry" "$(ls -l "${DATA}/admin-password" 2>&1)"
teardown

# bcrypt is only needed to hash a new password. A device whose security.json was
# written years ago needs none of it, and an interrupted upgrade is exactly how a
# boat ends up with a half-configured python3.
setup
printf '{"users":[]}\n' > "${SK}/security.json"
printf 'raise ImportError("python3-bcrypt is broken here")\n' > "${SANDBOX}/pylib/bcrypt.py"
check "a broken bcrypt does not wedge an already-configured device" "$(run_hook)" "0"
teardown

# A worn SD card fails by remounting read-only, and ext4 does it mid-run. Nothing
# can be redirected anywhere on a read-only filesystem, so failing to tighten a
# mode there is not a reason to leave the vessel without a navigation server.
setup
printf '{"users":[]}\n' > "${SK}/security.json"
chmod 644 "${SK}/security.json"
cat > "${SANDBOX}/pylib/sitecustomize.py" <<'SHIM'
import errno, os
def _fchmod(fd, mode):
    raise OSError(errno.EROFS, "Read-only file system")
os.fchmod = _fchmod
SHIM
check "a read-only filesystem does not stop the server starting" "$(run_hook)" "0"
grep -q "WARNING" "${SANDBOX}/out" &&
    ok "  and the failure is logged" || bad "  and the failure is logged" "$(cat "${SANDBOX}/out")"
teardown


# Pinning the parent by descriptor is the stated reason for doing this in python
# at all, and nothing above tests it: every hostile parent is planted before the
# run, where the type check clears it and the descriptor never matters. Here the
# directory is swapped *after* open_dir returned, which is the only condition
# dir_fd exists for. Re-resolving these paths instead writes the token into the
# attacker's directory.
setup
influx_available "tok-pinned"
cat > "${SANDBOX}/pylib/sitecustomize.py" <<SHIM
import os
_real_open, _swapped = os.open, []
def _open(path, flags, mode=0o777, *, dir_fd=None):
    fd = _real_open(path, flags, mode, dir_fd=dir_fd)
    # basename, so the swap still lands if the code under test resolves the
    # whole path instead of going through the parent descriptor -- which is the
    # regression this scenario exists to catch.
    if os.path.basename(path) == "plugin-config-data" and not _swapped:
        _swapped.append(True)
        os.rename("${SK}/plugin-config-data", "${SK}/pinned-dir")
        os.mkdir("${SK}/decoy-dir")
        os.symlink("${SK}/decoy-dir", "${SK}/plugin-config-data")
    return fd
os.open = _open
SHIM
check "a parent swapped after it was opened does not redirect the write" "$(run_hook)" "0"
[ -f "${SK}/pinned-dir/signalk-to-influxdb2.json" ] &&
    ok "  the config lands in the directory that was opened" ||
    bad "  the config lands in the directory that was opened" "$(ls -a "${SK}/pinned-dir" 2>&1)"
[ ! -e "${SK}/decoy-dir/signalk-to-influxdb2.json" ] &&
    ok "  and not in the one swapped in behind it" ||
    bad "  and not in the one swapped in behind it" "$(ls -a "${SK}/decoy-dir" 2>&1)"
teardown

# admin-password is only useful if it opens the account whose hash is in
# security.json. Writing the hash to both, or regenerating the password on every
# boot while security.json keeps the first hash, leaves every mode and ownership
# assertion above satisfied and emergency access dead -- discovered when OIDC is
# already broken and this is the way back in.
setup
run_hook > /dev/null
"${REAL_PYTHON3}" -c '
import bcrypt, json, sys
pw = open(sys.argv[1], "rb").read().strip()
hashed = json.load(open(sys.argv[2]))["users"][0]["password"].encode()
sys.exit(0 if bcrypt.checkpw(pw, hashed) else 1)
' "${DATA}/admin-password" "${SK}/security.json" 2>/dev/null &&
    ok "admin-password opens the admin account in security.json" ||
    bad "admin-password opens the admin account in security.json" \
        "$(head -c 60 "${DATA}/admin-password" 2>&1)"
# The emergency password must survive an ordinary restart: rewriting it while
# security.json keeps the old hash silently breaks the fallback.
BEFORE="$(cat "${DATA}/admin-password")"
run_hook > /dev/null
check "  and is not rewritten on the next boot" "$(cat "${DATA}/admin-password")" "${BEFORE}"
teardown

# The emergency password's protection is that root owns its parent. A chown of it
# to the container uid would hand over the one credential that is supposed to
# outlive a compromise, and nothing above would notice.
setup
influx_available "tok-chown"
run_hook > /dev/null
chowned "${DATA}/admin-password" &&
    bad "admin-password is not handed to the container" "it was chowned to 1000:1000" ||
    ok "admin-password is not handed to the container"
chowned "${SK}/plugin-config-data" &&
    ok "plugin-config-data is handed over" ||
    bad "plugin-config-data is handed over" "$(cat "${STUB_LOG}")"
teardown

setup
: > "${SK}/settings.json"
run_hook > /dev/null
chowned "${SK}/settings.json" &&
    ok "settings.json is handed over" ||
    bad "settings.json is handed over" "$(cat "${STUB_LOG}")"
teardown

# --- the gpsd liner migration ------------------------------------------------
#
# default-data is copy-if-absent, so correcting the baked connection reached new
# installs only. These devices are already shipped, and nothing else in the
# package ever rewrites the file they were seeded with.

setup
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
chmod 644 "${SK}/settings.json"
check "a pre-liner gpsd connection is migrated" "$(run_hook)" "0"
check "  the liner lands between the two elements" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/liner providers/nmea0183-signalk"
check "  and the file keeps its mode" "$(mode "${SK}/settings.json")" "644"
# The whole document, not just the pipeline: the rewrite serialises every key in
# the file, and a fielded settings.json carries the vessel uuid and mmsi, the
# interfaces settings and the ssl flag alongside pipedProviders.
migration_changed_nothing_else "${SK}/settings.json" "${SK}/settings.json.pre-liner" &&
    ok "  and nothing else in the document changes" ||
    bad "  and nothing else in the document changes" "$(cat "${SK}/settings.json")"
check "  the original is kept alongside" \
    "$(element_types "${SK}/settings.json.pre-liner")" \
    "providers/gpsd providers/nmea0183-signalk"
# The backup is what the operator is told to copy back. Landed 0600 it is
# unreadable to the uid that would restore it, and the instruction is dead.
check "  at the mode the original had" "$(mode "${SK}/settings.json.pre-liner")" "644"
# Root replaced a file the container owns and writes. Left root-owned, every
# later change made in the admin UI fails and the connection cannot be edited or
# deleted -- a repair that costs the operator the tool for repairing it.
chowned "${SK}/settings.json" &&
    ok "  and the rewritten file is handed back to the container" ||
    bad "  and the rewritten file is handed back to the container" "$(cat "${STUB_LOG}")"
chowned "${SK}/settings.json.pre-liner" &&
    ok "  as is the copy it kept" ||
    bad "  as is the copy it kept" "$(cat "${STUB_LOG}")"
teardown

# A device with a real NMEA connection alongside the gpsd one. The splice walks
# every provider, so the match cannot be pinned by a fixture that only ever has
# one -- narrowing the loop to pipedProviders[0] would pass every scenario above.
setup
printf '%s\n' '{"pipedProviders":[
  {"id":"n2k","pipeElements":[{"type":"providers/simple","options":{"type":"NMEA2000"}}]},
  {"id":"gpsd","pipeElements":[
    {"type":"providers/gpsd","options":{"hostname":"localhost"}},
    {"type":"providers/nmea0183-signalk"}]}]}' > "${SK}/settings.json"
check "a gpsd connection that is not the first is migrated" "$(run_hook)" "0"
check "  the other connection is untouched" \
    "$(element_types "${SK}/settings.json" 0)" "providers/simple"
check "  and the gpsd one gets the liner" \
    "$(element_types "${SK}/settings.json" 1)" \
    "providers/gpsd providers/liner providers/nmea0183-signalk"
teardown

# The hook runs on every boot, so the predicate has to stop matching what it
# produced. A second liner is not cosmetic: it splits already-split lines and the
# connection stays broken, now with no trace of what did it.
setup
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
run_hook > /dev/null
MIGRATED="$(cat "${SK}/settings.json")"
check "an already-migrated connection is left alone" "$(run_hook)" "0"
check "  byte for byte" "$(cat "${SK}/settings.json")" "${MIGRATED}"
check "  with no second liner" "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/liner providers/nmea0183-signalk"
teardown

# What the admin UI writes, and what a new install now seeds. The server
# assembles the pipeline from this, so there is nothing to splice -- and a device
# that was repaired by deleting and recreating the connection looks like this.
setup
cp "${REPO_ROOT}/apps/signalk-server/default-data/data/settings.json" "${SK}/settings.json"
BEFORE="$(cat "${SK}/settings.json")"
check "a providers/simple connection is left alone" "$(run_hook)" "0"
check "  unchanged" "$(cat "${SK}/settings.json")" "${BEFORE}"
[ ! -e "${SK}/settings.json.pre-liner" ] &&
    ok "  and nothing is backed up" ||
    bad "  and nothing is backed up" "a backup was written"
teardown

# The adjacency is the whole predicate, and that is what makes it also the
# unmodified check. gpsd piped into anything else is someone's own pipeline.
setup
printf '%s\n' '{"pipedProviders":[{"id":"gpsd","pipeElements":[
  {"type":"providers/gpsd"},{"type":"providers/log"},
  {"type":"providers/nmea0183-signalk"}]}]}' > "${SK}/settings.json"
BEFORE="$(cat "${SK}/settings.json")"
check "a pipeline we did not ship is left alone" "$(run_hook)" "0"
check "  unchanged" "$(cat "${SK}/settings.json")" "${BEFORE}"
teardown

# A fresh install has no settings.json until the postinst seeds default-data.
# Writing one here would bake a shape from this hook that default-data owns.
setup
check "no settings.json is invented when none exists" "$(run_hook)" "0"
[ ! -e "${SK}/settings.json" ] &&
    ok "  none is written" || bad "  none is written" "$(cat "${SK}/settings.json")"
teardown

# This is the first thing in the hook that ever writes settings.json, so the swap
# the secret files are hardened against now reaches this path too. The link
# target is a valid pre-liner config on purpose: pointed at plain text, a hook
# that followed the link would fail on the parse and look guarded.
setup
CANARY="${SANDBOX}/outside-the-data-root"
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${CANARY}"; chmod 644 "${CANARY}"
ln -s "${CANARY}" "${SK}/settings.json"
check "a symlinked settings.json is not migrated through the link" "$(run_hook)" "0"
check "  the link target keeps its two elements" \
    "$(element_types "${CANARY}")" "providers/gpsd providers/nmea0183-signalk"
check "  and its mode" "$(mode "${CANARY}")" "644"
teardown

# The rewrite lands through a sibling temp file, and uid 1000 owns the directory
# -- so that name is one root writes that no path guard covers unless the create
# itself refuses to follow it.
setup
CANARY="${SANDBOX}/outside-the-data-root"
printf 'original\n' > "${CANARY}"; chmod 644 "${CANARY}"
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
ln -s "${CANARY}" "${SK}/settings.json.halos-tmp"
check "a symlinked temp path does not redirect the migration" "$(run_hook)" "0"
check "  the link target is not written through" "$(cat "${CANARY}")" "original"
check "  and the connection is still migrated" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/liner providers/nmea0183-signalk"
teardown

# settings.json.tmp belongs to the server: atomicWriteFile stages every one of
# its own saves through it. A root-owned file left at that name fails the
# container's next write with EACCES, so the hook must not use it at all.
setup
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
printf 'the servers own staging file\n' > "${SK}/settings.json.tmp"
check "the server's own .tmp name is left alone" "$(run_hook)" "0"
check "  its contents are untouched" "$(cat "${SK}/settings.json.tmp")" \
    "the servers own staging file"
[ ! -e "${SK}/settings.json.halos-tmp" ] &&
    ok "  and the hook's staging file does not survive" ||
    bad "  and the hook's staging file does not survive" "halos-tmp was left behind"
teardown

# The backup carries the whole pre-migration file, so a redirected copy
# overwrites the link target with it. Planted inside the window rather than
# before the run: the sentinel check lstats this name first, so a symlink staged
# up front is a hit and the hook returns before the create is ever reached --
# which is the shape this scenario had until review caught it passing vacuously.
setup
CANARY="${SANDBOX}/outside-the-data-root"
printf 'original\n' > "${CANARY}"; chmod 644 "${CANARY}"
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
inject_before_open True "ln -sfn '${CANARY}' '${SK}/settings.json.pre-liner'" \
    settings.json.pre-liner
check "a backup path planted after the clear does not redirect the copy" "$(run_hook)" "0"
check "  the link target is not written through" "$(cat "${CANARY}")" "original"
check "  and the repair still stands" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/liner providers/nmea0183-signalk"
teardown

# A symlink already at that name before the run is the refusal path, not the
# write path: the sentinel means "this already ran", whatever the file is.
setup
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
ln -s /nonexistent "${SK}/settings.json.pre-liner"
check "anything at the backup name refuses the repair" "$(run_hook)" "0"
check "  the connection is left as it was" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/nmea0183-signalk"
teardown

# Restoring the backup is how an operator refuses the repair. Without it standing
# in for "this already ran", the next boot splices the connection again and there
# is no way to say no short of uninstalling the package.
setup
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
run_hook > /dev/null
cp "${SK}/settings.json.pre-liner" "${SK}/settings.json"
check "a restored pre-liner connection is left alone" "$(run_hook)" "0"
check "  the restore survives the next boot" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/nmea0183-signalk"
teardown

# Restoring with mv takes the record away with the copy, so the splice runs
# again. Pinned rather than fixed: the hook prints that the file has to stay, and
# a record separate from the backup would be a second file on every device for a
# gesture the message already covers.
setup
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
run_hook > /dev/null
mv "${SK}/settings.json.pre-liner" "${SK}/settings.json"
check "restoring with mv re-arms the splice" "$(run_hook)" "0"
check "  the connection is migrated again" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/liner providers/nmea0183-signalk"
teardown

# The repair goes down before the record of it, so a failure at the rename leaves
# settings.json untouched and nothing claiming the migration ran. Ordered the
# other way, this boot would retire the device: the next one reads the backup as
# a completed migration and never looks at the connection again.
setup
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
cat > "${SANDBOX}/pylib/sitecustomize.py" <<'SHIM'
import errno, os
_real = os.replace
def _replace(src, dst, *, src_dir_fd=None, dst_dir_fd=None):
    if dst == "settings.json":
        raise OSError(errno.EIO, "Input/output error")
    return _real(src, dst, src_dir_fd=src_dir_fd, dst_dir_fd=dst_dir_fd)
os.replace = _replace
SHIM
check "a migration that fails at the rename does not block the start" "$(run_hook)" "0"
check "  the connection is left as it was" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/nmea0183-signalk"
[ ! -e "${SK}/settings.json.pre-liner" ] &&
    ok "  and nothing is left claiming it ran" ||
    bad "  and nothing is left claiming it ran" "a backup survived the failure"
rm -f "${SANDBOX}/pylib/sitecustomize.py"
check "  so a later boot still migrates it" "$(run_hook)" "0"
check "  with the liner where it belongs" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/liner providers/nmea0183-signalk"
teardown

# The other end of that order: the repair has landed and only the copy fails. The
# device is fixed, so the next boot must not splice a second liner -- the file no
# longer matching is what carries idempotency here, not the record.
setup
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
cat > "${SANDBOX}/pylib/sitecustomize.py" <<'SHIM'
import errno, os
_real = os.open
def _open(path, flags, mode=0o777, *, dir_fd=None):
    if path == "settings.json.pre-liner" and (flags & os.O_CREAT):
        raise OSError(errno.ENOSPC, "No space left on device")
    return _real(path, flags, mode, dir_fd=dir_fd)
os.open = _open
SHIM
check "a failed backup does not cost the repair" "$(run_hook)" "0"
check "  the connection is migrated" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/liner providers/nmea0183-signalk"
rm -f "${SANDBOX}/pylib/sitecustomize.py"
check "  and the next boot adds no second liner" "$(run_hook)" "0"
check "  the pipeline still has exactly one" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/liner providers/nmea0183-signalk"
teardown

# A settings.json that will not parse is one Signal K cannot start from either.
# Rewriting it from a guess is worse than leaving it for the operator.
setup
printf 'not json at all\n' > "${SK}/settings.json"
check "an unparseable settings.json does not block the start" "$(run_hook)" "0"
check "  and is left as it was" "$(cat "${SK}/settings.json")" "not json at all"
grep -q "gpsd connection not migrated" "${SANDBOX}/out" &&
    ok "  and the reason is logged" ||
    bad "  and the reason is logged" "$(cat "${SANDBOX}/out")"
teardown

# The migration is a repair, not a precondition. A device that keeps the old
# connection shows no position, which is where it already was; a device whose
# ExecStartPre aborts has no navigation server at all. The licence to refuse to
# start belongs to security.json alone.
setup
printf '{"users":[]}\n' > "${SK}/security.json"
printf '%s\n' "${PRE_LINER_SETTINGS}" > "${SK}/settings.json"
chmod 555 "${SK}"
STATUS="$(run_hook)"
chmod 755 "${SK}"
check "an unwritable data directory does not block the start" "${STATUS}" "0"
check "  and the connection is left as it was" \
    "$(element_types "${SK}/settings.json")" \
    "providers/gpsd providers/nmea0183-signalk"
teardown

# Every other scenario asserts the hook exits 0, so nothing pins the deliberate
# refusal. Replacing it with a warning would start Signal K with no security
# configuration -- open, not degraded -- with the suite green. An unwritable
# parent is a fault the hook genuinely cannot clear.
setup
mkdir -p "${SK}/security.json"
chmod 555 "${SK}"
STATUS="$(run_hook)"
chmod 755 "${SK}"
[ "${STATUS}" != "0" ] &&
    ok "an unclearable security.json refuses to start" ||
    bad "an unclearable security.json refuses to start" "exited 0"
grep -q "refusing to start" "${SANDBOX}/out" &&
    ok "  and says why" || bad "  and says why" "$(cat "${SANDBOX}/out")"
teardown

# The hook is sourced by the generated prestart, so a false test at the end of it
# would become the whole unit's exit status.
setup
: > "${DATA}/admin-password"
check "a partially-populated data root still exits 0" "$(run_hook)" "0"
teardown

printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
