#!/bin/bash
# Exercise apps/signalk-server/provision.sh with stubbed docker/getent/curl.
#
# The hook decides whether a boot costs nothing or blocks Signal K indefinitely,
# and none of that is visible to a test that greps the file. This runs it: no
# Docker, no network, no root.
#
# Usage: tools/test-provision.sh
set -u

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOK="${REPO_ROOT}/apps/signalk-server/provision.sh"
pass=0
fail=0

ok()   { printf '  ok   %s\n' "$1"; pass=$((pass + 1)); }
bad()  { printf '  FAIL %s\n' "$1"; printf '       %s\n' "$2"; fail=$((fail + 1)); }
check(){ [ "$2" = "$3" ] && ok "$1" || bad "$1" "expected '$3', got '$2'"; }

# A sandbox with the hook, a manifest, a compose file, and stub binaries whose
# behaviour each case controls through STUB_* env vars.
setup() {
    SANDBOX="$(mktemp -d)"
    APP="${SANDBOX}/app"
    mkdir -p "${APP}/assets" "${SANDBOX}/bin" "${SANDBOX}/data/data"
    cp "${HOOK}" "${APP}/provision.sh"
    printf 'services:\n  app:\n    image: test/signalk:v1\n' > "${APP}/docker-compose.yml"
    printf '%s\n' "$@" > "${APP}/assets/plugins.list"

    cat > "${SANDBOX}/bin/docker" <<'STUB'
#!/bin/bash
[ "${1:-}" = "rm" ] && exit 0
echo "docker $*" >> "${STUB_LOG}"
if [ -n "${STUB_NPM_404:-}" ]; then
    echo "npm error code E404"
    echo "npm error 404 Not Found - GET https://registry.npmjs.org/${STUB_NPM_404}"
    exit 1
fi
[ -n "${STUB_NPM_FAIL:-}" ] && { echo "npm error network"; exit 1; }
# Success: create what a real install leaves behind.
pkg="${@: -1}"
mkdir -p "${STUB_PREFIX}/node_modules/${pkg}"
printf '{"name":"%s","version":"1.0.0"}\n' "${pkg}" > "${STUB_PREFIX}/node_modules/${pkg}/package.json"
python3 - "$pkg" <<'PY'
import json, os, sys
p = os.path.join(os.environ["STUB_PREFIX"], "package.json")
d = json.load(open(p)) if os.path.exists(p) else {}
d.setdefault("dependencies", {})[sys.argv[1]] = "^1.0.0"
json.dump(d, open(p, "w"))
PY
exit 0
STUB
    cat > "${SANDBOX}/bin/getent" <<'STUB'
#!/bin/bash
[ -n "${STUB_OFFLINE:-}" ] && exit 2
exit 0
STUB
    cat > "${SANDBOX}/bin/curl" <<'STUB'
#!/bin/bash
[ -n "${STUB_OFFLINE:-}" ] && exit 7
exit 0
STUB
    chmod 755 "${SANDBOX}/bin"/*
    STUB_LOG="${SANDBOX}/docker.log"; : > "${STUB_LOG}"
    STUB_PREFIX="${SANDBOX}/data/data"
    export STUB_LOG STUB_PREFIX
}

teardown() { rm -rf "${SANDBOX}"; unset STUB_OFFLINE STUB_NPM_FAIL STUB_NPM_404; }

run_hook() {  # $1 = seconds to allow; echoes exit status
    PATH="${SANDBOX}/bin:${PATH}" CONTAINER_DATA_ROOT="${SANDBOX}/data" \
        timeout "$1" bash "${APP}/provision.sh" > "${SANDBOX}/out" 2>&1
    echo $?
}

installed() {  # mark a package as fully installed, the way a real npm run leaves it
    mkdir -p "${STUB_PREFIX}/node_modules/$1"
    printf '{"name":"%s","version":"1.0.0"}\n' "$1" > "${STUB_PREFIX}/node_modules/$1/package.json"
    python3 - "$1" <<'PY'
import json, os, sys
p = os.path.join(os.environ["STUB_PREFIX"], "package.json")
d = json.load(open(p)) if os.path.exists(p) else {}
d.setdefault("dependencies", {})[sys.argv[1]] = "^1.0.0"
json.dump(d, open(p, "w"))
PY
}

echo "provision.sh behaviour"

setup "pkg-a" "pkg-b"
installed pkg-a; installed pkg-b
check "everything present exits 0" "$(run_hook 10)" "0"
check "  and runs no docker" "$(wc -l < "${STUB_LOG}" | tr -d ' ')" "0"
teardown

setup "pkg-a"
check "missing package is installed" "$(run_hook 10)" "0"
check "  with one docker run" "$(grep -c '^docker run' "${STUB_LOG}")" "1"
teardown

setup "pkg-a"
mkdir -p "${STUB_PREFIX}/node_modules/pkg-a"   # dir only, no package.json
check "bare directory counts as missing" "$(run_hook 10)" "0"
check "  so it is installed" "$(grep -c '^docker run' "${STUB_LOG}")" "1"
teardown

setup "pkg-a"
mkdir -p "${STUB_PREFIX}/node_modules/pkg-a"
printf '{"name":"pkg-a"}\n' > "${STUB_PREFIX}/node_modules/pkg-a/package.json"
check "unrecorded package counts as missing" "$(run_hook 10)" "0"
check "  so a truncated install is repaired" "$(grep -c '^docker run' "${STUB_LOG}")" "1"
teardown

setup "pkg-a"
export STUB_NPM_404=pkg-a
check "a 404 gives up with non-zero" "$(run_hook 10)" "1"
grep -q "does not exist in the registry" "${SANDBOX}/out" &&
    ok "  and names the package" || bad "  and names the package" "$(tail -2 "${SANDBOX}/out")"
teardown

setup "pkg-a"
export STUB_OFFLINE=1
check "offline keeps retrying (killed by timeout)" "$(run_hook 3)" "124"
grep -q "registry unreachable" "${SANDBOX}/out" &&
    ok "  and says why" || bad "  and says why" "$(tail -2 "${SANDBOX}/out")"
teardown

setup "pkg-a"
export STUB_NPM_FAIL=1
check "transient install failure retries" "$(run_hook 3)" "124"
teardown

setup "# only a comment" "" "pkg-a  " "pkg-a"
installed pkg-a
check "comments, blanks and whitespace parse" "$(run_hook 10)" "0"
check "  duplicate entry needs no install" "$(wc -l < "${STUB_LOG}" | tr -d ' ')" "0"
teardown

printf '\n%s passed, %s failed\n' "${pass}" "${fail}"
[ "${fail}" -eq 0 ]
