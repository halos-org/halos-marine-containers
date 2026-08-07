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

# --- secret files -----------------------------------------------------------
# security.json (admin hash + JWT signing key) and the InfluxDB token config are
# written by root into a directory this hook hands to uid 1000, so the container
# -- and any host process running as pi, the same uid -- can put something else
# at those names first.
#
# All of it happens in one python3 block, for reasons three rounds of shell got
# wrong:
#
#   * chmod(2) always dereferences and has no --no-dereference, so converging a
#     mode is only safe as open(O_NOFOLLOW) + fchmod.
#   * `set -o noclobber` is NOT O_EXCL. Bash stats the path first and adds
#     O_EXCL only when that stat fails, so a symlink to a FIFO or a device node
#     is followed -- and a FIFO with a reader made the hook log success while
#     streaming the secrets to whoever held the read end.
#   * Guarding named paths cannot cover a swapped *parent*, because every
#     syscall re-resolves the whole path. The parent is opened once here and
#     everything is *at-relative to that descriptor.
#   * Checking for a symlink was the wrong predicate: a plain `mkdir` at
#     security.json wedged ExecStartPre on every boot. The check is on the file
#     type, so a directory, FIFO, socket or device is handled too.
#
# The token is read before the block so python needs no shell interpolation.
INFLUXDB_ENV="${INFLUXDB_ENV:-/etc/container-apps/marine-influxdb-container/env}"
INFLUXDB_ADMIN_TOKEN=""
if [ -f "${INFLUXDB_ENV}" ]; then
    INFLUXDB_ADMIN_TOKEN=$(grep '^INFLUXDB_ADMIN_TOKEN=' "${INFLUXDB_ENV}" | cut -d= -f2-)
fi

HALOS_DATA_ROOT="${CONTAINER_DATA_ROOT}" \
HALOS_SK_DATA="${SIGNALK_DATA}" \
HALOS_INFLUX_TOKEN="${INFLUXDB_ADMIN_TOKEN}" \
python3 - <<'HALOS_SECRETS_PY'
import json, os, secrets, stat, sys

import bcrypt

DATA_ROOT = os.environ["HALOS_DATA_ROOT"]
SK_DATA = os.environ["HALOS_SK_DATA"]
INFLUX_TOKEN = os.environ.get("HALOS_INFLUX_TOKEN") or ""


def warn(msg):
    print("WARNING: " + msg, flush=True)


def open_dir(path, parent_fd=None):
    """Pin a directory by descriptor.

    Everything below operates *at-relative to this fd, so the parent cannot be
    swapped between one syscall and the next -- the gap no per-path check can
    close, because each syscall otherwise re-resolves the whole path.
    """
    return os.open(
        path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd
    )


def clear_unexpected(dfd, name, want_dir=False):
    """Make `name` absent or the type we need, without following anything.

    Root creates only a regular file (or, for the config dir, a directory) at
    these names. Anything else is tampering or wreckage, and the check is on
    the *type*, not on being a symlink: a plain `mkdir` at security.json wedged
    every boot, and a FIFO made the hook report success while streaming the
    secrets to whoever held the read end.

    A wrong-type directory is renamed aside rather than deleted -- it may hold
    an operator's data, and moving it both preserves that and unblocks the
    create. Everything else (symlink, FIFO, socket, device) is something root
    never creates here, so unlinking loses nothing.
    """
    try:
        st = os.lstat(name, dir_fd=dfd)
    except FileNotFoundError:
        return True

    if stat.S_ISDIR(st.st_mode) if want_dir else stat.S_ISREG(st.st_mode):
        return True

    kind = "directory" if stat.S_ISDIR(st.st_mode) else (
        "symlink" if stat.S_ISLNK(st.st_mode) else "non-regular file"
    )
    warn(f"unexpected {kind} at {name}; clearing it")
    try:
        if stat.S_ISDIR(st.st_mode):
            os.rename(name, name + ".unexpected",
                      src_dir_fd=dfd, dst_dir_fd=dfd)
            warn(f"moved aside to {name}.unexpected; its contents are intact")
        else:
            os.unlink(name, dir_fd=dfd)
    except OSError as exc:
        warn(f"could not clear {name}: {exc}")
        return False
    return True


def create_exclusive(dfd, name, content):
    """Create and fill `name`, refusing to follow anything.

    O_EXCL|O_NOFOLLOW is a real kernel exclusive create, and the mode is applied
    at creation so the secrets are never briefly world-readable. Bash's
    `noclobber` is NOT equivalent: it stats first and only adds O_EXCL when that
    stat fails, so a symlink to a FIFO or a device is followed.
    """
    fd = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=dfd,
    )
    try:
        os.fchmod(fd, 0o600)  # explicit: the mode above is masked by umask
        with os.fdopen(fd, "w") as f:
            f.write(content)
    except BaseException:
        os.close(fd)
        raise


def converge_mode(dfd, name):
    """Restrict an existing file without re-resolving its path.

    chmod(2) always dereferences and has no --no-dereference, so the only safe
    form is to open the file O_NOFOLLOW and fchmod the descriptor.
    """
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=dfd)
    except (FileNotFoundError, OSError):
        return
    try:
        os.fchmod(fd, 0o600)
    finally:
        os.close(fd)


# --- security.json -----------------------------------------------------------
# Failure here aborts the hook. A Signal K with no security configuration is
# not a degraded install, it is an open one, and the causes that remain after
# the type check above are real filesystem faults rather than anything the
# container can arrange.
sk_fd = open_dir(SK_DATA)
root_fd = open_dir(DATA_ROOT)

if not clear_unexpected(sk_fd, "security.json"):
    sys.exit("ERROR: cannot make security.json safe to write; refusing to start")

converge_mode(sk_fd, "security.json")

try:
    os.lstat("security.json", dir_fd=sk_fd)
except FileNotFoundError:
    print("Creating initial security.json with default admin user...")
    password = secrets.token_hex(16)
    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    create_exclusive(sk_fd, "security.json", json.dumps({
        "strategy": "./tokensecurity",
        "users": [{"username": "admin", "type": "admin", "password": hashed}],
        "allow_readonly": True,
        "secretKey": secrets.token_hex(32),
    }, indent=2) + "\n")

    # Emergency access only; OIDC is the normal login path. Its parent is
    # root-owned and outside the bind mount, but it is created the same way so
    # the rule holds by construction rather than by luck.
    clear_unexpected(root_fd, "admin-password")
    try:
        os.unlink("admin-password", dir_fd=root_fd)
    except FileNotFoundError:
        pass
    create_exclusive(root_fd, "admin-password", password + "\n")
    print("Security initialized with admin user.")
    print(f"NOTE: Local admin password stored in {DATA_ROOT}/admin-password")
    print("This is a fallback for emergency access. Use OIDC for regular login.")

# --- InfluxDB plugin config --------------------------------------------------
# Failure here only warns. Logging is not navigation, and the alternative is a
# unit that never starts.
if INFLUX_TOKEN:
    if clear_unexpected(sk_fd, "plugin-config-data", want_dir=True):
        try:
            os.mkdir("plugin-config-data", 0o755, dir_fd=sk_fd)
        except FileExistsError:
            pass
        try:
            cfg_fd = open_dir("plugin-config-data", parent_fd=sk_fd)
        except OSError as exc:
            cfg_fd = None
            warn(f"cannot open plugin-config-data: {exc}")

        if cfg_fd is not None:
            name = "signalk-to-influxdb2.json"
            if clear_unexpected(cfg_fd, name):
                converge_mode(cfg_fd, name)
                try:
                    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW,
                                 dir_fd=cfg_fd)
                except FileNotFoundError:
                    create_exclusive(cfg_fd, name, json.dumps({
                        "enabled": True,
                        "configuration": {"influxes": [{
                            "url": "http://localhost:8086",
                            "token": INFLUX_TOKEN,
                            "org": "marine",
                            "bucket": "marine",
                            "onlySelf": True,
                            "resolution": 1000,
                        }]},
                    }, indent=2) + "\n")
                    print("InfluxDB plugin configured")
                else:
                    # Read through the descriptor, not the path: json.load on a
                    # re-planted symlink would copy a root-only file out, and
                    # os.replace would then leave it here owned by uid 1000.
                    try:
                        with os.fdopen(fd) as f:
                            cfg = json.load(f)
                        influxes = cfg.get("configuration", {}).get("influxes", [])
                        if influxes:
                            influxes[0]["token"] = INFLUX_TOKEN
                        tmp = name + ".tmp"
                        clear_unexpected(cfg_fd, tmp)
                        try:
                            os.unlink(tmp, dir_fd=cfg_fd)
                        except FileNotFoundError:
                            pass
                        create_exclusive(cfg_fd, tmp,
                                         json.dumps(cfg, indent=2) + "\n")
                        os.replace(tmp, name,
                                   src_dir_fd=cfg_fd, dst_dir_fd=cfg_fd)
                        print("InfluxDB plugin token updated")
                    except (OSError, ValueError) as exc:
                        warn(f"failed to update InfluxDB token: {exc}")
            os.close(cfg_fd)

os.close(sk_fd)
os.close(root_fd)
HALOS_SECRETS_PY

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
# Unconditional, not inside a create branch: the python block above may have
# created security.json on this run or on any earlier one, and the container
# cannot log anyone in through a file it does not own.
if [ -f "${SECURITY_FILE}" ]; then
    chown -h 1000:1000 "${SECURITY_FILE}"
fi
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
