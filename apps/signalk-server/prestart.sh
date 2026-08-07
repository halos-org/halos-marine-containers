#!/bin/bash
# Signal K Server app-prestart hook (sourced by the generated framework prestart).
# OIDC is declarative now (routing.auth.mode: oidc): the framework provisions the
# client secret, writes the Authelia snippet, and appends SIGNALK_OIDC_CLIENT_SECRET
# /_ISSUER/_REDIRECT_URI to runtime.env. This hook keeps the Signal K-specific
# steps: the security.json bootstrap, external-URL advertising, and the InfluxDB
# logging plugin.

SIGNALK_DATA="${CONTAINER_DATA_ROOT}/data"
SECURITY_FILE="${SIGNALK_DATA}/security.json"
PLUGIN_CONFIG_DIR="${SIGNALK_DATA}/plugin-config-data"
PLUGIN_CONFIG="${PLUGIN_CONFIG_DIR}/signalk-to-influxdb2.json"

# Create data directory if needed
mkdir -p "${SIGNALK_DATA}"

# Root writes the files below, and their parent is handed to uid 1000 at the end
# of this hook -- so the container can unlink any of them and leave a symlink in
# its place. Every operation that follows dereferences: chmod, touch, cat >, and
# the chown on security.json. Left unguarded that is a container-to-host-root
# escalation, reproduced against /etc/ld.so.preload: root creates the target,
# writes the JSON into it, and hands it to uid 1000, which then writes a .so path
# every later root process preloads. The existing-target variant is a tamper
# primitive on its own -- the chmod 600 alone strips the mode off whatever the
# link points at.
#
# Root never creates a symlink at any of these paths, so removing one is only
# ever undoing tampering. node_modules further down is deliberately different:
# a symlink there can be an operator relocating the plugin tree to another disk,
# so only a dangling one is cleared.
#
# Failing to clear one aborts the hook rather than writing through it. The
# framework sources this under set -e, so a non-zero return here withholds the
# app -- the correct outcome when the alternative is root writing to a path the
# container chose.
drop_symlink() {  # $1 = path, $2 = optional consequence to warn about
    [ -L "$1" ] || return 0
    echo "WARNING: removing unexpected symlink at $1"
    [ -n "${2:-}" ] && echo "WARNING: $2"
    # -rf rather than -f: between the test above and this line the path can turn
    # into a real directory, which rm -f refuses -- and a non-zero return here
    # withholds the app on every boot until someone runs reset-failed by hand.
    # Root can always clear a path whose parent it owns, so give it the chance
    # before failing. Only a path that was a symlink a moment ago reaches this,
    # so nothing an operator put here deliberately is at risk.
    rm -rf "$1" || {
        echo "ERROR: could not remove ${1}; refusing to write through it"
        return 1
    }
}
# Parent before child: clearing a symlinked directory changes what the paths
# below it resolve to.
drop_symlink "${PLUGIN_CONFIG_DIR}"
drop_symlink "${SECURITY_FILE}" \
    "a fresh security.json follows: the admin password and the JWT signing key are regenerated, so existing tokens and device approvals stop validating, and whatever the link pointed at is left where it is"
drop_symlink "${PLUGIN_CONFIG}"

# Earlier versions created both of these 0644, so every already-deployed device
# carries the admin hash, the JWT signing key and the InfluxDB admin token in a
# world-readable file. Restricted here rather than only at creation, because on
# those devices the file already exists. Everything created below is written
# restricted in the first place.
if [ -f "${SECURITY_FILE}" ]; then
    chmod 600 "${SECURITY_FILE}"
fi
if [ -f "${PLUGIN_CONFIG}" ]; then
    chmod 600 "${PLUGIN_CONFIG}"
fi

# Only create security.json if it doesn't exist
if [ ! -f "${SECURITY_FILE}" ]; then
    echo "Creating initial security.json with default admin user..."

    # Generate a random password (32 character hex string)
    ADMIN_PASSWORD=$(openssl rand -hex 16)

    # Hash the password using Python bcrypt (via stdin for robustness)
    # python3-bcrypt is a dependency of the package
    HASHED_PASSWORD=$(printf '%s' "${ADMIN_PASSWORD}" | python3 -c "import sys, bcrypt; print(bcrypt.hashpw(sys.stdin.buffer.read(), bcrypt.gensalt()).decode())")

    # Generate a secret key for JWT tokens
    SECRET_KEY=$(openssl rand -hex 32)

    # Holds the admin bcrypt hash and the JWT signing key.
    #
    # noclobber, not touch-then-chmod: it makes bash open with O_CREAT|O_EXCL,
    # which refuses to follow a symlink at the final component. The guard near
    # the top clears a link that is already there, but the container owns this
    # directory and can plant one in the window between that check and here --
    # O_EXCL closes the window instead of narrowing it, in one syscall. umask
    # 077 means the secrets are 0600 from creation rather than briefly 0644
    # between touch and chmod. Subshell so neither setting leaks to the rest of
    # the hook.
    (
        umask 077
        set -o noclobber
        cat > "${SECURITY_FILE}" << EOF
{
  "strategy": "./tokensecurity",
  "users": [
    {
      "username": "admin",
      "type": "admin",
      "password": "${HASHED_PASSWORD}"
    }
  ],
  "allow_readonly": true,
  "secretKey": "${SECRET_KEY}"
}
EOF
    )

    # Set proper ownership (match container user - node:node is 1000:1000).
    # -h like every other chown here, so a link planted between the O_EXCL create
    # above and this line is not followed. With the create no longer
    # dereferencing, this is the last operation in the branch that could.
    chown -h 1000:1000 "${SECURITY_FILE}"

    echo "Security initialized with admin user."
    echo "NOTE: Local admin password stored in ${CONTAINER_DATA_ROOT}/admin-password"
    echo "This is a fallback for emergency access. Use OIDC for regular login."

    # Store the password for emergency recovery
    touch "${CONTAINER_DATA_ROOT}/admin-password"
    chmod 600 "${CONTAINER_DATA_ROOT}/admin-password"
    echo "${ADMIN_PASSWORD}" > "${CONTAINER_DATA_ROOT}/admin-password"
fi

# Signal K advertises its external URL via mDNS from these. EXTERNALHOST strips
# the .local suffix that Signal K's dnssd library re-appends; the external port
# comes from the routing registry, defaulting to the HTTPS port. Appended to the
# framework-owned runtime.env (the OIDC vars are written there by the framework).
EXTERNAL_PORT="$(grep '^signalk-server=' /etc/halos/port-registry 2>/dev/null | cut -d= -f2)"
{
    echo "EXTERNALHOST=${HALOS_DOMAIN%.local}"
    echo "EXTERNALPORT=${EXTERNAL_PORT:-443}"
    # Requires upstream EXTERNALSSL support: https://github.com/SignalK/signalk-server/pull/2484
    echo "EXTERNALSSL=1"
} >> "$RUNTIME_ENV"

# --- InfluxDB plugin configuration ---
# signalk-to-influxdb2 is baked into the image, so the data volume cannot attest
# to it. A presence check under ${SIGNALK_DATA}/node_modules is false on every
# freshly imaged device -- nothing puts the plugin there any more -- and writing
# the token config is then skipped for the whole life of that device, silently:
# the server starts, and only the graphs stay empty. The token lives in the
# InfluxDB container's env and is rewritten here on every start, because rotating
# it there must reach this config.
INFLUXDB_ENV="${INFLUXDB_ENV:-/etc/container-apps/marine-influxdb-container/env}"

if [ -f "${INFLUXDB_ENV}" ]; then
    INFLUXDB_ADMIN_TOKEN=$(grep '^INFLUXDB_ADMIN_TOKEN=' "${INFLUXDB_ENV}" | cut -d= -f2-)

    if [ -n "${INFLUXDB_ADMIN_TOKEN}" ]; then
        # Write plugin config (first time only) or update token
        mkdir -p "${PLUGIN_CONFIG_DIR}"
        if [ ! -f "${PLUGIN_CONFIG}" ]; then
            # Carries the InfluxDB admin token. umask + noclobber for the same
            # reason as security.json above: O_CREAT|O_EXCL will not follow a
            # symlink planted after the guard ran, and the token is never
            # briefly world-readable.
            (
            umask 077
            set -o noclobber
            cat > "${PLUGIN_CONFIG}" << PLUGINEOF
{
  "enabled": true,
  "configuration": {
    "influxes": [
      {
        "url": "http://localhost:8086",
        "token": "${INFLUXDB_ADMIN_TOKEN}",
        "org": "marine",
        "bucket": "marine",
        "onlySelf": true,
        "resolution": 1000
      }
    ]
  }
}
PLUGINEOF
            )
            echo "InfluxDB plugin configured"
        else
            # Update token in existing config without overwriting other settings
            # Rewritten via a temp file and os.replace: truncating the live path
            # means a kill between open('w') and the dump leaves it zero-length,
            # and every later boot then fails json.load, warns, and carries on
            # with the plugin's settings gone for good. apps/influxdb/prestart.sh
            # writes the same class of file the same way.
            if INFLUX_TOKEN="${INFLUXDB_ADMIN_TOKEN}" python3 - "${PLUGIN_CONFIG}" <<'PYEOF'; then
import json, os, sys
path = sys.argv[1]
with open(path) as f:
    cfg = json.load(f)
influxes = cfg.get('configuration', {}).get('influxes', [])
if influxes:
    influxes[0]['token'] = os.environ['INFLUX_TOKEN']
# O_EXCL rather than open(tmp, 'w'): this directory is handed to uid 1000 on
# every run, so the container can pre-create the temp path as a symlink and
# redirect root's write exactly as it could the config itself. O_CREAT|O_EXCL
# refuses to follow a symlink at the final component, and does it in one
# syscall -- unlike a check-then-write guard, there is no window to lose. The
# unlink clears a leftover from a killed run; if the link is re-planted in
# between, the open fails and the shell branch below reports it, which is the
# right direction to fail.
tmp = path + '.tmp'
try:
    os.unlink(tmp)
except FileNotFoundError:
    pass
fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
os.fchmod(fd, 0o600)  # explicit: the mode above is masked by umask
with os.fdopen(fd, 'w') as f:
    json.dump(cfg, f, indent=2)
os.replace(tmp, path)
PYEOF
                echo "InfluxDB plugin token updated"
            else
                echo "WARNING: Failed to update InfluxDB token in plugin config"
            fi
        fi
    fi
fi

# Reclaim what the retired provisioning hook left behind. npm-cache holds the
# tarballs and metadata for the whole curated set -- easily hundreds of MB on an
# SD card -- and .provisioned holds a dpkg version string nothing reads any more.
# Neither is inside the container's mount, so the container will never clear
# them, and no maintainer script does either. Guarded on the root being set: this
# runs as root on every boot.
if [ -n "${CONTAINER_DATA_ROOT:-}" ]; then
    rm -rf "${CONTAINER_DATA_ROOT}/npm-cache" "${CONTAINER_DATA_ROOT}/.provisioned"
fi

# The container runs as node:node while this script runs as root, so what root
# creates here has to be handed over. Named paths only: a recursive chown of the
# data root walks the whole plugin tree on every boot.
# -h throughout: these live in a directory the container can write, so following
# a symlink would let it choose which host path root hands over.
chown -h 1000:1000 "${SIGNALK_DATA}"
if [ -f "${SIGNALK_DATA}/settings.json" ]; then
    chown -h 1000:1000 "${SIGNALK_DATA}/settings.json"
fi

# The app store installs plugin updates into this tree as uid 1000, and that is
# the only route by which a baked plugin stays updatable. Both paths are created
# root-owned by things that run before Signal K ever starts -- signalk-halpi's
# postinst registers itself as a file: dependency, creating node_modules and
# package.json as root, and the pi-gen plugin stages do the same on an imaged
# device. Left root-owned, every app-store install fails EACCES forever.
# Non-recursive on purpose: what is already inside belongs to the container.
#
# The dangling-symlink case has to be cleared first, and the framework prestart
# is why: it runs under set -e and sources this hook as a statement, so any
# non-zero status here fails ExecStartPre and the server never starts. mkdir -p
# does not create through a dangling symlink -- it exits 1 -- and uid 1000 owns
# this directory, so leaving one there would wedge the unit on every boot with
# nothing to clear it. A symlink to a directory that exists is left alone: that
# is someone relocating the plugin tree to another disk, mkdir -p accepts it,
# and chown -h then touches the link rather than whatever it points at.
if [ -L "${SIGNALK_DATA}/node_modules" ] && [ ! -e "${SIGNALK_DATA}/node_modules" ]; then
    rm -f "${SIGNALK_DATA}/node_modules"
fi
# The chown belongs inside the success branch. Tolerating the mkdir and then
# chowning unconditionally would trade one abort for another -- chown on a path
# that does not exist is itself non-zero -- turning "the server runs, plugin
# updates are broken" back into "the server never starts".
if mkdir -p "${SIGNALK_DATA}/node_modules"; then
    chown -h 1000:1000 "${SIGNALK_DATA}/node_modules"
else
    echo "WARNING: could not create ${SIGNALK_DATA}/node_modules; plugin updates will fail"
fi
if [ -f "${SIGNALK_DATA}/package.json" ]; then
    chown -h 1000:1000 "${SIGNALK_DATA}/package.json"
fi
if [ -d "${PLUGIN_CONFIG_DIR}" ]; then
    chown -Rh 1000:1000 "${PLUGIN_CONFIG_DIR}"
fi
