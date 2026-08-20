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

# The compose file, not the env file. `apt remove` leaves a package in
# `deinstall ok config-files`: /etc/container-apps/marine-questdb-container/env
# and the systemd unit both survive, and only `apt purge` takes them. The
# compose file is payload and goes on either. Gating on env made "the app is
# gone" false for the ordinary uninstall, which left settings.json naming a
# provider that can never register -- and that is a standing warn notification,
# not a quiet fallback. Verified on a device.
QUESTDB_COMPOSE="${QUESTDB_COMPOSE:-/var/lib/container-apps/marine-questdb-container/docker-compose.yml}"
QUESTDB_INSTALLED=""
if [ -f "${QUESTDB_COMPOSE}" ]; then
    QUESTDB_INSTALLED=1
fi

HALOS_DATA_ROOT="${CONTAINER_DATA_ROOT}" \
HALOS_SK_DATA="${SIGNALK_DATA}" \
HALOS_INFLUX_TOKEN="${INFLUXDB_ADMIN_TOKEN}" \
HALOS_QUESTDB_INSTALLED="${QUESTDB_INSTALLED}" \
python3 -P - <<'HALOS_SECRETS_PY'
import errno, json, os, secrets, stat, sys

DATA_ROOT = os.environ["HALOS_DATA_ROOT"]
SK_DATA = os.environ["HALOS_SK_DATA"]
INFLUX_TOKEN = os.environ.get("HALOS_INFLUX_TOKEN") or ""
QUESTDB_INSTALLED = bool(os.environ.get("HALOS_QUESTDB_INSTALLED"))

# A racer that wins once will usually lose the next attempt; one that wins every
# attempt is not a race we can outlast, and refusing to start is then correct.
ATTEMPTS = 4

# Declared in the plugin's own code, not derived from its package name, and it is
# the key the history provider registry and settings.json both index by.
QUESTDB_PLUGIN_ID = "signalk-questdb-history-provider"


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


def create_exclusive(dfd, name, content, mode=0o600):
    """Create and fill `name`, refusing to follow anything.

    O_EXCL|O_NOFOLLOW is a real kernel exclusive create. Bash's `noclobber` is
    not equivalent: it stats first and only adds O_EXCL when that stat fails, so
    a symlink to a FIFO or a device is followed.

    The default is the secret-file mode. It is a parameter because settings.json
    holds no secret and is read and written by the container: tightening it to
    0600 as a side effect of rewriting it would be a second, silent change.
    """
    fd = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        mode,
        dir_fd=dfd,
    )
    try:
        os.fchmod(fd, mode)  # explicit: the mode above is masked by umask
    except BaseException:
        os.close(fd)
        raise
    # UTF-8 explicitly: every caller writes JSON, and text mode would otherwise
    # encode it in the process locale.
    with os.fdopen(fd, "w", encoding="utf-8") as f:  # owns fd, including on failure
        f.write(content)


def create_guarded(dfd, name, content, replace=False, mode=0o600):
    """Clear the name and create it, conceding only after losing repeatedly.

    O_EXCL turns a lost race into EEXIST instead of a write through whatever was
    planted, which is the point. Treating that EEXIST as fatal would hand the
    same racer an ExecStartPre failure on demand, so the loss costs a retry.

    `replace` is for a name this hook owns and rewrites rather than creates once:
    a regenerated secret, whose old file no longer opens anything, and the temp
    files the atomic writes stage through. Without it the O_EXCL create fails
    against the hook's own last run -- and `clear_unexpected` will not remove the
    leftover, because a regular file is exactly the type it wants there.
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
            create_exclusive(dfd, name, content, mode)
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


def read_settings(sk_fd):
    """Parse settings.json into (settings, mode, original), None when absent.

    Two writers below need the same three things, and each of them is a way to
    corrupt a value neither writer was asked to touch. The mode is the permission
    bits uid 1000 chose, kept because root recreates the file. UTF-8 is explicit
    because settings.json is UTF-8 by specification while text mode would decode
    it in the process locale -- under a single-byte locale a vessel name comes
    back as two characters that json.dumps then re-escapes. The original text is
    what the migration keeps as its backup.
    """
    try:
        fd = open_regular(sk_fd, "settings.json")
    except FileNotFoundError:
        return None  # a fresh install has none until the postinst seeds default-data

    with os.fdopen(fd, encoding="utf-8") as f:  # owns fd from here
        # Permission bits only. S_IMODE keeps setuid and setgid as well -- root
        # would otherwise reproduce them on a file it creates here.
        mode = stat.S_IMODE(os.fstat(f.fileno()).st_mode) & 0o777
        original = f.read()

    settings = json.loads(original)
    if not isinstance(settings, dict):
        raise ValueError(
            "settings.json is a %s, not an object" % type(settings).__name__
        )
    return settings, mode, original


def write_settings(sk_fd, settings, mode):
    """Replace settings.json atomically. False when the staged write failed."""
    # Not settings.json.tmp: that is the name the server's own atomic write stages
    # through, so a leftover there is a root-owned file in its way and its next
    # save fails EACCES.
    tmp = "settings.json.halos-tmp"
    body = json.dumps(settings, indent=2) + "\n"
    if not create_guarded(sk_fd, tmp, body, replace=True, mode=mode):
        return False
    # renameat replaces the name and never follows it, so a symlink swapped in
    # after the read above is overwritten rather than written through.
    os.replace(tmp, "settings.json", src_dir_fd=sk_fd, dst_dir_fd=sk_fd)
    return True


def open_plugin_config_dir(sk_fd):
    """Descriptor for plugin-config-data, or None when it cannot be made safe.

    Both plugin configs land here, in a directory uid 1000 owns, so the type
    check and the mkdir live in one place. Two copies of this could drift, and
    the half that drifted would write a config through whatever was planted at
    that name.
    """
    if not clear_unexpected(sk_fd, "plugin-config-data", want_dir=True):
        warn("cannot make plugin-config-data safe to write; skipping")
        return None
    try:
        os.mkdir("plugin-config-data", 0o755, dir_fd=sk_fd)
    except FileExistsError:
        pass
    return open_dir("plugin-config-data", parent_fd=sk_fd)


def configure_questdb(sk_fd):
    """Point the history provider at the QuestDB app. Never fatal.

    Written once and then left alone, unlike the InfluxDB config below. That one
    is rewritten every boot because a rotating token has to reach it; this one
    carries no secret, so a rewrite could only ever discard what the operator
    changed -- path filters, sampling rates, retention.

    Host and ports are written explicitly even though they are the plugin's
    defaults. A rebase onto a new upstream may move those defaults, and a
    device's configuration should not follow silently.
    """
    cfg_fd = open_plugin_config_dir(sk_fd)
    if cfg_fd is None:
        return
    try:
        name = QUESTDB_PLUGIN_ID + ".json"
        if not clear_unexpected(cfg_fd, name):
            warn("cannot make %s safe to write; skipping" % name)
            return

        converge_mode(cfg_fd, name)
        try:
            fd = open_regular(cfg_fd, name)
        except FileNotFoundError:
            pass
        else:
            os.close(fd)
            return

        if create_guarded(cfg_fd, name, json.dumps({
            "enabled": True,
            "configuration": {
                "questdbHost": "127.0.0.1",
                "questdbHttpPort": 9000,
                "questdbIlpPort": 9009,
            },
        }, indent=2) + "\n"):
            print("QuestDB history provider configured")
    finally:
        os.close(cfg_fd)


def clear_gone_default_history_provider(sk_fd, installed):
    """Drop settings.json's default history provider when its app is gone.

    Only that. Installing the QuestDB app does not make it the default, because
    naming it would take the slot from whatever is already serving history on
    that device -- and on a device that has run InfluxDB since before QuestDB
    existed, the key is absent not because nobody chose but because there was
    never anything to choose between. The operator picks, in the admin UI under
    Apps & Plugins -> Configuration, and Signal K records the first provider to
    register on a device that has never had one (SignalK/signalk-server#2981).

    A key naming a gone provider is a standing alarm rather than a fallback: the
    first history request after the app is removed raises a warn notification at
    notifications.server.history.defaultProvider ("Configured default history
    provider ... is not available"), and the server clears it only when that
    provider registers again, which for an uninstalled app is never. Verified on
    a device. Hence this one direction.

    Exact match only. Any other value is the operator's, and the only value this
    removes is one naming the app that just went away.
    """
    if installed:
        return
    read = read_settings(sk_fd)
    if read is None:
        return
    settings, mode, _ = read

    history = settings.get("historyApi")
    if not isinstance(history, dict):
        # Absent, or malformed and not root's to interpret.
        return

    if history.get("defaultProvider") != QUESTDB_PLUGIN_ID:
        return
    del history["defaultProvider"]

    settings["historyApi"] = history
    if write_settings(sk_fd, settings, mode):
        print("QuestDB is gone; cleared it as the default history provider")
    else:
        warn("could not clear the default history provider")


def configure_influx(sk_fd, token):
    """Point the logging plugin at InfluxDB. Never fatal; see the call site."""
    cfg_fd = open_plugin_config_dir(sk_fd)
    if cfg_fd is None:
        return
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

        # `replace` because this name is one the hook owns and rewrites: without
        # it, a .tmp left by an interrupted run survives clear_unexpected (a
        # regular file is the wanted type) and every later O_EXCL create fails
        # EEXIST, so the token is never refreshed again on that device.
        tmp = name + ".tmp"
        if not create_guarded(cfg_fd, tmp, json.dumps(cfg, indent=2) + "\n",
                              replace=True):
            warn("cannot write %s; leaving the config alone" % tmp)
            return
        os.replace(tmp, name, src_dir_fd=cfg_fd, dst_dir_fd=cfg_fd)
        print("InfluxDB plugin token updated")
    finally:
        os.close(cfg_fd)


# REMOVE AFTER 2027-08-01. This repairs one closed population -- devices seeded
# between v0.3.1+13 and the providers/simple fix -- and every boot after the last
# of them has been repaired, reimaged or retired is a root write into a
# container-owned directory bought for nothing. What goes with it:
#
#   * migrate_gpsd_liner and its call site
#   * the settings.json.pre-liner hand_over below (the settings.json one above it
#     predates this and stays -- the postinst creates that file root-owned)
#   * in tools/test-prestart.sh: the "the gpsd liner migration" scenarios, the
#     element_types helper and the PRE_LINER_SETTINGS fixture
#   * the gpsd paragraphs in AGENTS.md
#
# What does NOT go with it: read_settings, write_settings, the `mode` parameter
# they need on create_exclusive and create_guarded, and the settings.json
# hand_over. clear_gone_default_history_provider writes the file too, and unlike
# this it has no expiry -- so removing this leaves settings.json a path the hook
# still writes, on every device the QuestDB app was removed from.
def migrate_gpsd_liner(sk_fd):
    """Splice the missing Liner into a gpsd connection seeded before the fix.

    gpsd writes a whole NMEA reporting cycle in one TCP write, so a pipeline that
    hands it straight to the parser delivers several sentences as one blob and
    every burst is rejected -- no position, at any server version. `default-data`
    is copy-if-absent, so correcting the baked file reached new installs only:
    every device seeded from v0.3.1+13 onward keeps the broken pipeline, while
    apt reports success and the app version bumps.

    The adjacency is the whole predicate, and it doubles as the unmodified check.
    The server marks only a single `providers/simple` element editable, so the
    hand-authored connection renders in the admin UI as a read-only textarea
    whose one action is Delete -- no device reached this shape by being
    configured. A connection recreated through the UI is one `providers/simple`
    element; a hand-repaired one already has three. Neither matches.

    Only the Liner goes in. Rewriting the connection to `providers/simple`, which
    is what a new install now seeds, would discard a hand-edited host or port and
    change the connection's identity in the admin UI -- more than repairing the
    defect we shipped.

    settings.json needs the same discipline as the secret files above, and for a
    different reason: what makes it dangerous is root writing into a directory
    uid 1000 owns, not the contents.

    ExecStartPre is where this belongs because the unit stops the container before
    it restarts, so Signal K -- the file's other writer -- is normally not running
    while this rewrites it. Normally, not always: the compose file sets
    `restart: unless-stopped` and the unit is only `After=docker.service`, so an
    unclean shutdown leaves the container in dockerd's restore set and it can be
    up again before this runs. `docker compose up` then attaches to it instead of
    recreating it, and the server keeps the settings it read at its own start --
    so on that boot the repair lands on disk without reaching the running server,
    and takes effect at the next start that actually recreates the container.
    """
    backup = "settings.json.pre-liner"

    # The backup doubles as the record that this already ran, which is what keeps
    # a repair from becoming a standing policy: an operator who restores the old
    # connection deliberately would otherwise have it spliced again on the next
    # boot, with no way to refuse short of uninstalling the package. Checked
    # before settings.json is opened, so no early return below owns a descriptor.
    try:
        os.lstat(backup, dir_fd=sk_fd)
        return
    except FileNotFoundError:
        pass

    read = read_settings(sk_fd)
    if read is None:
        return
    settings, mode, original = read

    spliced = False
    for provider in settings.get("pipedProviders") or []:
        elements = provider.get("pipeElements") if isinstance(provider, dict) else None
        if not isinstance(elements, list):
            continue
        for i in range(len(elements) - 1):
            pair = elements[i:i + 2]
            if all(isinstance(e, dict) for e in pair) and [
                e.get("type") for e in pair
            ] == ["providers/gpsd", "providers/nmea0183-signalk"]:
                elements.insert(i + 1, {"type": "providers/liner"})
                spliced = True
                break

    if not spliced:
        return

    if not write_settings(sk_fd, settings, mode):
        warn("cannot stage the rewrite; leaving the gpsd connection alone")
        return

    print("Added the missing providers/liner to the gpsd connection")

    # The record of the repair goes down after the repair, never before. Anything
    # that stops the hook above this line leaves settings.json untouched and no
    # backup, so the next boot tries again; stopping below it costs the undo copy
    # and not the repair. Ordering it the other way makes a half-written backup
    # read as a completed migration and retires the device for good.
    # Caught here rather than at the call site: by this point the repair has
    # landed, and the call site's handler would report it as not migrated.
    try:
        kept = create_guarded(sk_fd, backup, original, mode=mode)
    except OSError as exc:
        kept = False
        warn("could not keep a copy of the previous connection: %s" % exc)
    if kept:
        print("The connection as it was is kept at %s/%s" % (SK_DATA, backup))
        print("Leave that file in place: it also stops this running again")


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

# A repair, not a precondition: a device left on the old connection shows no
# position, which is where it already was, while an exception on the way there is
# an ExecStartPre abort and no navigation server at all.
try:
    migrate_gpsd_liner(sk_fd)
except Exception as exc:
    warn("gpsd connection not migrated: %s" % exc)

# Logging is not navigation: a failure here must not cost the boot.
if INFLUX_TOKEN:
    try:
        configure_influx(sk_fd, INFLUX_TOKEN)
    except Exception as exc:
        warn("InfluxDB plugin config not updated: %s" % exc)

if QUESTDB_INSTALLED:
    try:
        configure_questdb(sk_fd)
    except Exception as exc:
        warn("QuestDB plugin config not written: %s" % exc)

# Unconditional, unlike the plugin config above: this runs to clear the key on
# a device the app was removed from, which is a state only reachable with
# QUESTDB_INSTALLED false. Separate from the config for the rest -- they fail
# for different reasons, and history still works when only a stale key remains.
try:
    clear_gone_default_history_provider(sk_fd, QUESTDB_INSTALLED)
except Exception as exc:
    warn("default history provider not cleared: %s" % exc)

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
# The migration writes this one as root, and it is the file the operator is told
# to copy back. Left root-owned, that instruction needs a shell on the host.
if [ -f "${SIGNALK_DATA}/settings.json.pre-liner" ]; then
    hand_over "${SIGNALK_DATA}/settings.json.pre-liner"
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
