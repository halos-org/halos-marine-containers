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

# Create data directory if needed
mkdir -p "${SIGNALK_DATA}"

# --- secret files -----------------------------------------------------------
# security.json (admin hash + JWT signing key) and the InfluxDB token config are
# written by root into a directory this hook hands to uid 1000, so the container
# -- and any host process running as pi, the same uid -- can put something else
# at those names first.
#
# All of it happens in one python3 block, because the shell cannot express the
# constraints:
#
#   * chmod(2) always dereferences and has no --no-dereference, so converging a
#     mode is only safe as open(O_NOFOLLOW) + fchmod.
#   * `set -o noclobber` is NOT O_EXCL. Bash stats the path first and adds
#     O_EXCL only when that stat fails, so a symlink to a FIFO or a device node
#     is followed.
#   * Guarding named paths cannot cover a swapped *parent*, because every
#     syscall re-resolves the whole path. The parents are opened once here and
#     everything is *at-relative to those descriptors.
#   * The predicate is the file type, not "is a symlink": a directory, FIFO,
#     socket or device at one of these names has to be handled too.
#   * O_NOFOLLOW refuses a symlink but not a FIFO, and opening a FIFO to read
#     blocks until a writer appears -- for root as much as anyone. Reads add
#     O_NONBLOCK and check the type through the descriptor.
#
# Refusing to start is the answer when security.json cannot be made safe: an
# open Signal K is worse than an absent one. That licence is narrow. An abort
# the container can trigger on demand, or one caused by a fault that redirects
# nothing, is a permanent outage bought for nothing -- ExecStartPre gets five
# restarts before systemd stops trying.
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
python3 -P - <<'HALOS_SECRETS_PY'
import errno, json, os, secrets, stat, sys

DATA_ROOT = os.environ["HALOS_DATA_ROOT"]
SK_DATA = os.environ["HALOS_SK_DATA"]
INFLUX_TOKEN = os.environ.get("HALOS_INFLUX_TOKEN") or ""

# A racer that wins once will usually lose the next attempt; one that wins every
# attempt is not a race we can outlast, and refusing to start is then correct.
ATTEMPTS = 4


def warn(msg):
    print("WARNING: " + msg, flush=True)


def open_dir(path, parent_fd=None):
    """Pin a directory by descriptor.

    Everything below is *at-relative to this fd, so the parent cannot be swapped
    between one syscall and the next -- the gap no per-path check can close,
    because each syscall otherwise re-resolves the whole path.
    """
    return os.open(
        path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=parent_fd
    )


def open_regular(dfd, name):
    """Open an existing regular file for reading, without following or blocking.

    O_NOFOLLOW refuses a symlink but not a FIFO, and a FIFO opened for reading
    blocks until a writer appears. The type has to be checked through the
    descriptor: checking the name first would be a different object by the time
    the open ran.
    """
    fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=dfd)
    if not stat.S_ISREG(os.fstat(fd).st_mode):
        os.close(fd)
        raise OSError(errno.EINVAL, "not a regular file", name)
    return fd


def move_aside(dfd, name):
    """Rename a wrong-type directory out of the way, to a name that is free.

    A fixed destination is not free: occupying it makes every rename fail, and
    aborting on that hands anyone who can write here a permanent boot wedge. A
    run that already moved one aside collides with its own leftover the same way.
    """
    for suffix in [".unexpected"] + [
        ".unexpected.%s" % secrets.token_hex(4) for _ in range(ATTEMPTS)
    ]:
        try:
            os.rename(name, name + suffix, src_dir_fd=dfd, dst_dir_fd=dfd)
        except FileNotFoundError:
            return True
        except OSError:
            continue
        warn("moved aside to %s%s; its contents are intact" % (name, suffix))
        return True
    warn("could not move %s aside; every candidate name is taken" % name)
    return False


def clear_unexpected(dfd, name, want_dir=False):
    """Make `name` absent or the type we need, without following anything.

    Returns True when the name is now safe to create at -- absent, or already the
    wanted type -- and False only when something is still in the way.

    Root creates only a regular file (or, for the config dir, a directory) at
    these names, so anything else is tampering or wreckage. A wrong-type
    directory is renamed rather than deleted: it may hold an operator's data.
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
    warn("unexpected %s at %s; clearing it" % (kind, name))
    if stat.S_ISDIR(st.st_mode):
        return move_aside(dfd, name)
    try:
        os.unlink(name, dir_fd=dfd)
    except FileNotFoundError:
        pass  # someone else removed it; absent is the state we wanted
    except OSError as exc:
        warn("could not clear %s: %s" % (name, exc))
        return False
    return True


def create_exclusive(dfd, name, content):
    """Create and fill `name`, refusing to follow anything.

    O_EXCL|O_NOFOLLOW is a real kernel exclusive create. Bash's `noclobber` is
    not equivalent: it stats first and only adds O_EXCL when that stat fails, so
    a symlink to a FIFO or a device is followed.
    """
    fd = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o600,
        dir_fd=dfd,
    )
    try:
        os.fchmod(fd, 0o600)  # explicit: the mode above is masked by umask
    except BaseException:
        os.close(fd)
        raise
    with os.fdopen(fd, "w") as f:  # owns fd from here, including on failure
        f.write(content)


def create_guarded(dfd, name, content, replace=False):
    """Clear the name and create it, conceding only after losing repeatedly.

    O_EXCL turns a lost race into EEXIST instead of a write through whatever was
    planted, which is the point. Treating that EEXIST as fatal would hand the
    same racer an ExecStartPre failure on demand, so the loss costs a retry.

    `replace` is for a value being regenerated rather than created once: the old
    file is a stale copy of a secret that no longer opens anything, so it goes.
    Without it the O_EXCL create would fail against the hook's own last run.
    """
    for _ in range(ATTEMPTS):
        if not clear_unexpected(dfd, name):
            return False
        if replace:
            try:
                os.unlink(name, dir_fd=dfd)
            except FileNotFoundError:
                pass
            except OSError as exc:
                warn("could not replace %s: %s" % (name, exc))
                return False
        try:
            create_exclusive(dfd, name, content)
            return True
        except FileExistsError:
            warn("%s reappeared between the clear and the create; retrying" % name)
    return False


def converge_mode(dfd, name):
    """Restrict an existing file without re-resolving its path.

    Failing to tighten a mode warrants a warning, never a refusal to boot: on a
    read-only filesystem, which is how a worn SD card fails, nothing can be
    redirected anywhere either.
    """
    try:
        fd = open_regular(dfd, name)
    except FileNotFoundError:
        return
    except OSError as exc:
        warn("could not open %s to check its mode: %s" % (name, exc))
        return
    try:
        os.fchmod(fd, 0o600)
    except OSError as exc:
        warn("could not tighten the mode on %s: %s" % (name, exc))
    finally:
        os.close(fd)


def configure_influx(sk_fd, token):
    """Point the logging plugin at InfluxDB. Never fatal; see the call site."""
    if not clear_unexpected(sk_fd, "plugin-config-data", want_dir=True):
        warn("cannot make plugin-config-data safe to write; skipping")
        return
    try:
        os.mkdir("plugin-config-data", 0o755, dir_fd=sk_fd)
    except FileExistsError:
        pass

    cfg_fd = open_dir("plugin-config-data", parent_fd=sk_fd)
    try:
        name = "signalk-to-influxdb2.json"
        if not clear_unexpected(cfg_fd, name):
            warn("cannot make %s safe to write; skipping" % name)
            return

        converge_mode(cfg_fd, name)
        try:
            fd = open_regular(cfg_fd, name)
        except FileNotFoundError:
            if create_guarded(cfg_fd, name, json.dumps({
                "enabled": True,
                "configuration": {"influxes": [{
                    "url": "http://localhost:8086",
                    "token": token,
                    "org": "marine",
                    "bucket": "marine",
                    "onlySelf": True,
                    "resolution": 1000,
                }]},
            }, indent=2) + "\n"):
                print("InfluxDB plugin configured")
            return

        # Read through the descriptor, not the path: json.load on a re-planted
        # symlink would copy a root-only file out, and os.replace would then
        # leave it here owned by uid 1000.
        with os.fdopen(fd) as f:
            cfg = json.load(f)
        if not isinstance(cfg, dict):
            raise ValueError("config is a %s, not an object" % type(cfg).__name__)
        influxes = cfg.get("configuration", {}).get("influxes", [])
        if influxes:
            influxes[0]["token"] = token

        tmp = name + ".tmp"
        if not create_guarded(cfg_fd, tmp, json.dumps(cfg, indent=2) + "\n"):
            warn("cannot write %s; leaving the config alone" % tmp)
            return
        os.replace(tmp, name, src_dir_fd=cfg_fd, dst_dir_fd=cfg_fd)
        print("InfluxDB plugin token updated")
    finally:
        os.close(cfg_fd)


sk_fd = open_dir(SK_DATA)
root_fd = open_dir(DATA_ROOT)

if not clear_unexpected(sk_fd, "security.json"):
    sys.exit("ERROR: cannot make security.json safe to write; refusing to start")

converge_mode(sk_fd, "security.json")

# A regular file here means an existing install. Testing only for existence
# would accept whatever a racer left after the clear above -- a FIFO at this name
# is not a security configuration, and skipping the create branch on account of
# it starts Signal K with none.
try:
    existing = stat.S_ISREG(os.lstat("security.json", dir_fd=sk_fd).st_mode)
except FileNotFoundError:
    existing = False

if not existing:
    import bcrypt  # only a new install hashes anything

    print("Creating initial security.json with default admin user...")
    password = secrets.token_hex(16)

    # admin-password goes first. It is emergency access when OIDC is what broke,
    # and it exists only in memory until it lands -- writing security.json first
    # and failing here would make every later boot skip this branch, losing the
    # password for the life of the device. Its parent is root-owned and outside
    # the bind mount, but it is created the same way so the rule holds by
    # construction rather than by luck.
    if not create_guarded(root_fd, "admin-password", password + "\n", replace=True):
        sys.exit("ERROR: cannot write the emergency admin password; refusing to start")

    hashed = bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()
    if not create_guarded(sk_fd, "security.json", json.dumps({
        "strategy": "./tokensecurity",
        "users": [{"username": "admin", "type": "admin", "password": hashed}],
        "allow_readonly": True,
        "secretKey": secrets.token_hex(32),
    }, indent=2) + "\n"):
        sys.exit("ERROR: cannot make security.json safe to write; refusing to start")

    print("Security initialized with admin user.")
    print("NOTE: Local admin password stored in %s/admin-password" % DATA_ROOT)
    print("This is a fallback for emergency access. Use OIDC for regular login.")

# Logging is not navigation: a failure here must not cost the boot.
if INFLUX_TOKEN:
    try:
        configure_influx(sk_fd, INFLUX_TOKEN)
    except Exception as exc:
        warn("InfluxDB plugin config not updated: %s" % exc)

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
#
# Each of these tests a path and then chowns it as a separate command, in a
# directory the container owns. Removing the file in between makes chown exit
# non-zero, and under the framework's set -e that is an ExecStartPre failure --
# so a vanished path warns rather than taking the navigation server down. A path
# that is gone needs no chown.
hand_over() {  # $1 = path, $2... = extra chown flags
    local path="$1"; shift
    chown -h "$@" 1000:1000 "${path}" ||
        echo "WARNING: could not hand ${path} to the container"
}

hand_over "${SIGNALK_DATA}"
# Unconditional, not inside a create branch: the python block above may have
# created security.json on this run or on any earlier one, and the container
# cannot log anyone in through a file it does not own.
if [ -f "${SECURITY_FILE}" ]; then
    hand_over "${SECURITY_FILE}"
fi
if [ -f "${SIGNALK_DATA}/settings.json" ]; then
    hand_over "${SIGNALK_DATA}/settings.json"
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
    hand_over "${SIGNALK_DATA}/node_modules"
else
    echo "WARNING: could not create ${SIGNALK_DATA}/node_modules; plugin updates will fail"
fi
if [ -f "${SIGNALK_DATA}/package.json" ]; then
    hand_over "${SIGNALK_DATA}/package.json"
fi
if [ -d "${PLUGIN_CONFIG_DIR}" ]; then
    hand_over "${PLUGIN_CONFIG_DIR}" -R
fi
