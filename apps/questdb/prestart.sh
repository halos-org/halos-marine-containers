#!/bin/bash
# QuestDB app-prestart hook (sourced by the generated framework prestart).
#
# QuestDB memory-maps every partition column file and every WAL segment, so a
# grown database exhausts the stock vm.max_map_count of 65530. mmap then fails
# while plenty of RAM is free: queries error and WAL apply suspends, which reads
# as "recording stopped" with nothing in the logs about memory. The limit is
# kernel-global rather than per-namespace, so neither a container sysctl flag
# nor anything inside the container reaches it -- it has to be set on the host.
#
# The framework prestart runs as ExecStartPre under `set -e`, so a non-zero
# status here keeps the container down and eventually latches the unit in
# `failed`. A host that will not take the sysctl should still get a running
# QuestDB, so errexit is off for the hook and every problem warns and carries on.
set +e

RECOMMENDED_MAX_MAP_COUNT=1048576
SYSCTL_FILE="/etc/sysctl.d/99-questdb.conf"
SYSCTL_PATH="/proc/sys/vm/max_map_count"

questdb_warn() {
    echo "WARNING: $*" >&2
}

current=$(cat "${SYSCTL_PATH}" 2>/dev/null)
if [ -z "${current}" ]; then
    questdb_warn "could not read vm.max_map_count; leaving ${SYSCTL_FILE} untouched"
    exit 0
fi

# The drop-in is what survives a reboot; the live value is what this boot uses.
# Both are checked because either can be missing on its own: a fresh install has
# neither, and an install whose drop-in was written before a kernel parameter
# override still boots with the old value.
if [ ! -f "${SYSCTL_FILE}" ]; then
    if ! printf 'vm.max_map_count=%s\n' "${RECOMMENDED_MAX_MAP_COUNT}" > "${SYSCTL_FILE}"; then
        questdb_warn "could not write ${SYSCTL_FILE}; QuestDB may exhaust its memory mappings once the database grows"
        exit 0
    fi
    echo "Wrote ${SYSCTL_FILE} (vm.max_map_count=${RECOMMENDED_MAX_MAP_COUNT})"
fi

if [ "${current}" -lt "${RECOMMENDED_MAX_MAP_COUNT}" ]; then
    if sysctl -q -w "vm.max_map_count=${RECOMMENDED_MAX_MAP_COUNT}"; then
        echo "Raised vm.max_map_count from ${current} to ${RECOMMENDED_MAX_MAP_COUNT}"
    else
        questdb_warn "vm.max_map_count is ${current}, below the ${RECOMMENDED_MAX_MAP_COUNT} QuestDB needs, and could not be raised; a grown database will fail queries and suspend recording"
    fi
fi

exit 0
