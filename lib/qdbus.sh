#!/usr/bin/env bash
# qdbus discovery and invocation wrapper.

# Role: Locate a usable qdbus executable, preferring Qt 6 variants on modern KDE.
ka_qdbus_find() {
    local candidate
    if [[ -n ${KEEPALIVE_QDBUS:-} && -x ${KEEPALIVE_QDBUS:-} ]]; then
        KA_QDBUS=$KEEPALIVE_QDBUS
        return 0
    fi

    for candidate in qdbus6 qdbus-qt6 qdbus /usr/lib/qt6/bin/qdbus qdbus-qt5 /usr/lib/qt5/bin/qdbus; do
        if command -v "$candidate" >/dev/null 2>&1; then
            KA_QDBUS=$candidate
            return 0
        fi
    done
    KA_QDBUS=''
    return 1
}

# Role: Return a validated positive qdbus subprocess timeout in integer seconds.
ka_qdbus_timeout_seconds() {
    local value=${KEEPALIVE_QDBUS_TIMEOUT:-2}
    ka_is_positive_int "$value" || value=2
    printf '%s' "$value"
}

# Role: Invoke qdbus under a hard deadline so one D-Bus call cannot stall the daemon.
ka_qdbus_exec() {
    [[ -n ${KA_QDBUS:-} ]] || ka_qdbus_find || return 127
    command -v timeout >/dev/null 2>&1 || return 127
    local limit
    limit=$(ka_qdbus_timeout_seconds)
    timeout --kill-after=1s "${limit}s" "$KA_QDBUS" "$@"
}

# Role: Identify GNU timeout exit statuses that represent a bounded subprocess expiry.
ka_qdbus_status_is_timeout() {
    [[ ${1-} == 124 || ${1-} == 137 ]]
}

# Role: Invoke qdbus with stderr suppressed for probing operations.
ka_qdbus_call() {
    ka_qdbus_exec "$@" 2>/dev/null
}

# Role: List currently registered Konsole D-Bus service names for this user session.
ka_qdbus_konsole_services() {
    local output rc
    if output=$(ka_qdbus_exec 2>/dev/null); then
        :
    else
        rc=$?
        return "$rc"
    fi
    grep -oE 'org\.kde\.konsole(-[0-9]+)?$' <<<"$output" || true
}
