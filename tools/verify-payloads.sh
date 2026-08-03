#!/bin/bash
# Verify each app's runtime payload actually reached its .deb.
#
# The generator packages a fixed set of paths, so a file an app adds outside that
# set is copied by nothing and no build error is raised. A hook then finds no
# manifest at runtime and the feature is silently inert -- which is exactly how a
# curated plugin set once shipped doing nothing.
#
# Usage: verify-payloads.sh <repo-root> <build-dir>
set -uo pipefail

REPO_ROOT="${1:?usage: verify-payloads.sh <repo-root> <build-dir>}"
BUILD_DIR="${2:?usage: verify-payloads.sh <repo-root> <build-dir>}"

if ! command -v dpkg-deb >/dev/null 2>&1; then
    echo "WARNING: dpkg-deb not available; skipping payload verification" >&2
    exit 0
fi

errors=0
checked=0

for app_dir in "${REPO_ROOT}/apps"/*; do
    [ -d "$app_dir" ] || continue
    app_name=$(basename "$app_dir")
    expected=()
    [ -f "$app_dir/provision.sh" ] && expected+=("provision.sh")
    while IFS= read -r asset; do
        [ -n "$asset" ] && expected+=("assets/${asset#"$app_dir/assets/"}")
    done < <(find "$app_dir/assets" -type f 2>/dev/null)

    # Not `ls | head -1`: with a stale .deb beside the fresh one that picks by
    # name order, so the check can pass against a package this build did not
    # produce. Ambiguity is an error here, not a coin flip.
    debs=()
    while IFS= read -r found; do
        [ -n "$found" ] && debs+=("$found")
    done < <(find "${BUILD_DIR}" -maxdepth 1 -name "marine-${app_name}-container_*.deb" 2>/dev/null)

    if [ ${#debs[@]} -gt 1 ]; then
        echo "ERROR: ${app_name}: ${#debs[@]} .debs in ${BUILD_DIR}; cannot tell which is current" >&2
        errors=$((errors + 1))
        continue
    fi

    deb=""
    if [ ${#debs[@]} -eq 1 ]; then
        deb="${debs[0]}"
    fi

    if [ -z "$deb" ]; then
        # Skipping silently is how this check would report success on a build that
        # produced nothing -- the failure it exists to catch.
        if [ ${#expected[@]} -gt 0 ]; then
            echo "ERROR: ${app_name} has payload to verify but no .deb was built" >&2
            errors=$((errors + 1))
        fi
        continue
    fi

    contents=$(dpkg-deb -c "$deb")
    lib_dir="/var/lib/container-apps/marine-${app_name}-container"

    if [ -f "$app_dir/provision.sh" ]; then
        checked=$((checked + 1))
        unit="/etc/systemd/system/marine-${app_name}-container-provision.service"
        if ! grep -q "${unit}\$" <<<"$contents"; then
            echo "ERROR: ${app_name}: ships provision.sh but no provisioning unit" >&2
            errors=$((errors + 1))
        fi
    fi

    for path in ${expected+"${expected[@]}"}; do
        checked=$((checked + 1))
        if ! grep -q "${lib_dir}/${path}\$" <<<"$contents"; then
            echo "ERROR: ${app_name}: ${path} is in the app definition but not in the .deb" >&2
            errors=$((errors + 1))
        fi
    done
done

if [ "$errors" -gt 0 ]; then
    echo "ERROR: ${errors} expected file(s) missing from built packages" >&2
    exit 1
fi

if [ "$checked" -eq 0 ]; then
    echo "ERROR: verified nothing -- no app payload was found to check" >&2
    exit 1
fi

echo "Package payloads verified (${checked} file(s) across all apps)"
