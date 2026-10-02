#!/usr/bin/env bash
# KDE/freedesktop desktop notification helpers.

# Role: Report whether desktop notifications can be attempted on this host.
ka_notify_available() {
    if [[ -n ${KEEPALIVE_NOTIFY_SEND:-} ]]; then
        [[ -x $KEEPALIVE_NOTIFY_SEND ]]
    else
        command -v notify-send >/dev/null 2>&1
    fi
}

# Role: Invoke notify-send under a hard deadline and expose its transport status.
ka_notify_call() {
    ka_notify_available || return 127
    command -v timeout >/dev/null 2>&1 || return 127
    local command=${KEEPALIVE_NOTIFY_SEND:-notify-send}
    ka_tunable KEEPALIVE_NOTIFY_TIMEOUT 2
    timeout --kill-after=1s "${REPLY}s" "$command" "$@"
}

# Role: Send a bounded best-effort desktop notification; failures never stop keep-alive work.
ka_notify() {
    local title=$1 body=$2 urgency=${3:-normal}
    ka_notify_available || return 0
    # notify-send may pass these strings to a markup-capable notification server. Apply
    # the same terminal-safe filter first, then escape markup metacharacters in order.
    ka_sanitize_human_set "$title"; title=$REPLY
    ka_sanitize_human_set "$body"; body=$REPLY
    title=${title//&/\&amp;}; title=${title//</\&lt;}; title=${title//>/\&gt;}
    body=${body//&/\&amp;}; body=${body//</\&lt;}; body=${body//>/\&gt;}
    ka_notify_call -a 'Keep Alive' -u "$urgency" -t 4000 -- "$title" "$body" >/dev/null 2>&1 || true
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
