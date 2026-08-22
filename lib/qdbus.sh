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

# Role: Resolve the per-call D-Bus deadline into KA_DBUS_TIMEOUT without forking.
# Every bounded call needed this value, and reading it through a command substitution
# cost one fork per call on the daemon's hottest path.
ka_dbus_timeout_resolve() {
    local value=${KEEPALIVE_QDBUS_TIMEOUT:-2}
    ka_is_positive_int "$value" || value=2
    KA_DBUS_TIMEOUT=$value
}

# Role: Return a validated positive qdbus subprocess timeout in integer seconds.
ka_qdbus_timeout_seconds() {
    ka_dbus_timeout_resolve
    printf '%s' "$KA_DBUS_TIMEOUT"
}

# Role: Invoke qdbus under a hard deadline so one D-Bus call cannot stall the daemon.
ka_qdbus_exec() {
    [[ -n ${KA_QDBUS:-} ]] || ka_qdbus_find || return 127
    command -v timeout >/dev/null 2>&1 || return 127
    ka_dbus_timeout_resolve
    timeout --kill-after=1s "${KA_DBUS_TIMEOUT}s" "$KA_QDBUS" "$@"
}

# Role: Identify GNU timeout exit statuses that represent a bounded subprocess expiry.
ka_qdbus_status_is_timeout() {
    [[ ${1-} == 124 || ${1-} == 137 ]]
}

# Role: Invoke qdbus with stderr suppressed for probing operations.
ka_qdbus_call() {
    ka_qdbus_exec "$@" 2>/dev/null
}

# Role: Locate the lightweight dbus-send client used for read-only session queries.
# Measured on the review workstation, one shellSessionId read costs 12.8 ms of CPU
# through qdbus6 and 2.4 ms through dbus-send, because qdbus6 pays Qt startup on every
# invocation. Read-only polling dominates daemon CPU, so this is the single largest win.
ka_dbus_send_find() {
    if [[ -n ${KEEPALIVE_DBUS_SEND:-} && -x ${KEEPALIVE_DBUS_SEND:-} ]]; then
        KA_DBUS_SEND=$KEEPALIVE_DBUS_SEND
        return 0
    fi
    if command -v dbus-send >/dev/null 2>&1; then
        KA_DBUS_SEND=dbus-send
        return 0
    fi
    KA_DBUS_SEND=''
    return 1
}

# Role: Report whether read-only calls may use dbus-send instead of qdbus.
# An explicit KEEPALIVE_QDBUS pins the qdbus path; that is how the test suite injects
# its mock, and how an operator can force the original transport.
ka_dbus_use_send() {
    [[ -z ${KEEPALIVE_QDBUS:-} && -n ${KA_DBUS_SEND:-} ]]
}

# Role: Invoke one D-Bus method through dbus-send and print its scalar reply.
# `--print-reply=literal` still prefixes non-string types, so the type token is stripped.
ka_dbus_send_scalar() {
    local service=$1 path=$2 member=$3 out rc
    command -v timeout >/dev/null 2>&1 || return 127
    ka_dbus_timeout_resolve
    if out=$(timeout --kill-after=1s "${KA_DBUS_TIMEOUT}s" "$KA_DBUS_SEND" --session --print-reply=literal \
        --dest="$service" "$path" "$member" 2>/dev/null); then :; else
        rc=$?
        return "$rc"
    fi
    out=${out#"${out%%[![:space:]]*}"}
    out=${out%"${out##*[![:space:]]}"}
    case $out in
        'int16 '*|'int32 '*|'int64 '*|'uint16 '*|'uint32 '*|'uint64 '*|'byte '*|'double '*|'boolean '*|'string '*)
            out=${out#* }
            ;;
    esac
    printf '%s' "$out"
}

# Role: List currently registered Konsole D-Bus service names for this user session.
ka_qdbus_konsole_services() {
    local output rc
    if ka_dbus_use_send; then
        if output=$(ka_dbus_send_scalar org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus.ListNames 2>/dev/null); then :; else
            rc=$?
            return "$rc"
        fi
        tr ' ' '\n' <<<"$output" | grep -oE 'org\.kde\.konsole(-[0-9]+)?$' || true
        return 0
    fi
    if output=$(ka_qdbus_exec 2>/dev/null); then
        :
    else
        rc=$?
        return "$rc"
    fi
    grep -oE 'org\.kde\.konsole(-[0-9]+)?$' <<<"$output" || true
}
