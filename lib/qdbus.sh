#!/usr/bin/env bash
# qdbus discovery and invocation wrapper.

# Role: Percent-escape one D-Bus address value into REPLY.
ka_dbus_escape_address_value() {
    local value=$1 output='' byte hex i LC_ALL=C
    for ((i = 0; i < ${#value}; i++)); do
        byte=${value:i:1}
        case $byte in
            [[:alnum:]_./-]) output+=$byte ;;
            *)
                # Mask to the byte itself: musl's C locale reports a high byte as
                # 0xDF00 plus the byte, glibc as the byte (see ka_sanitize_human_set).
                printf -v hex '%d' "'$byte"
                printf -v hex '%02X' "$((hex & 255))"
                output+="%$hex"
                ;;
        esac
    done
    REPLY=$output
}

# Role: Use the standard systemd user-bus socket when the manager did not import its address.
ka_dbus_prepare_session_address() {
    [[ -n ${DBUS_SESSION_BUS_ADDRESS:-} ]] && return 0
    [[ -n ${KA_RUNTIME_BASE:-} && -S $KA_RUNTIME_BASE/bus ]] || return 0
    ka_dbus_escape_address_value "$KA_RUNTIME_BASE/bus"
    export DBUS_SESSION_BUS_ADDRESS="unix:path=$REPLY"
}

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
    ka_tunable KEEPALIVE_QDBUS_TIMEOUT 2
    KA_DBUS_TIMEOUT=$REPLY
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
# Matched with builtin regexes, which is what the former tr/grep pipelines did at the cost
# of two processes on every discovery pass, and with the same units: dbus-send prints the
# names as space-separated array items, so each item is tested; qdbus prints one per line,
# so each line is tested and must end in the name, exactly as the old anchored grep did.
ka_qdbus_konsole_services() {
    local output rc item name_re='org\.kde\.konsole(-[0-9]+)?$'
    local -a items=()
    if ka_dbus_use_send; then
        if output=$(ka_dbus_send_scalar org.freedesktop.DBus /org/freedesktop/DBus \
            org.freedesktop.DBus.ListNames 2>/dev/null); then :; else
            rc=$?
            return "$rc"
        fi
        output=${output// /$'\n'}
    elif output=$(ka_qdbus_exec 2>/dev/null); then
        :
    else
        rc=$?
        return "$rc"
    fi
    mapfile -t items <<<"$output"
    for item in "${items[@]}"; do
        [[ $item =~ $name_re ]] && printf '%s\n' "${BASH_REMATCH[0]}"
    done
    return 0
}
