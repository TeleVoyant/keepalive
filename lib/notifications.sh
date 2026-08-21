#!/usr/bin/env bash
# KDE/freedesktop desktop notification helpers.

# Role: Report whether desktop notifications can be attempted on this host.
ka_notify_available() {
    command -v notify-send >/dev/null 2>&1
}

# Role: Send a non-blocking desktop notification; failures never stop keep-alive work.
ka_notify() {
    local title=$1 body=$2 urgency=${3:-normal}
    ka_notify_available || return 0
    notify-send -a 'Keep Alive' -u "$urgency" -t 4000 -- "$title" "$body" >/dev/null 2>&1 || true
}

# Role: Notify after a successful automatic/manual keep-alive delivery when enabled.
ka_notify_sent() {
    local enabled=$1 name=$2 detail=$3
    [[ $enabled == 1 ]] || return 0
    ka_notify "Keep Alive · $name" "sent: $detail" normal
}

# Role: Notify when a requested keep-alive send fails after target validation.
ka_notify_send_failed() {
    local enabled=$1 name=$2 detail=$3
    [[ $enabled == 1 ]] || return 0
    ka_notify "Keep Alive send failed · $name" "$detail" critical
}

# Role: Notify when a previously active/paused target becomes permanently unavailable.
ka_notify_target_lost() {
    local enabled=$1 name=$2 reason=$3
    [[ $enabled == 1 ]] || return 0
    ka_notify "Keep Alive target lost · $name" "$reason" critical
}
