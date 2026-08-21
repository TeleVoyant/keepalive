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

# Role: Invoke qdbus with stderr suppressed for probing operations.
ka_qdbus_call() {
    [[ -n ${KA_QDBUS:-} ]] || ka_qdbus_find || return 127
    "$KA_QDBUS" "$@" 2>/dev/null
}

# Role: List currently registered Konsole D-Bus service names for this user session.
ka_qdbus_konsole_services() {
    [[ -n ${KA_QDBUS:-} ]] || ka_qdbus_find || return 127
    "$KA_QDBUS" 2>/dev/null | grep -oE 'org\.kde\.konsole(-[0-9]+)?$' || true
}
