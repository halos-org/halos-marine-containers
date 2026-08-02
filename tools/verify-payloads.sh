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
    deb=$(ls "${BUILD_DIR}/marine-${app_name}-container_"*.deb 2>/dev/null | head -1)
    [ -n "$deb" ] || continue

    contents=$(dpkg-deb -c "$deb")
    lib_dir="/var/lib/container-apps/marine-${app_name}-container"

    expected=()
    [ -f "$app_dir/provision.sh" ] && expected+=("provision.sh")
    while IFS= read -r asset; do
        [ -n "$asset" ] && expected+=("assets/${asset#"$app_dir/assets/"}")
    done < <(find "$app_dir/assets" -type f 2>/dev/null)

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

echo "Package payloads verified (${checked} file(s) across all apps)"
