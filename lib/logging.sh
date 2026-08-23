#!/usr/bin/env bash
# Per-target runtime event logging. Logs intentionally live under XDG_RUNTIME_DIR
# and therefore do not survive a full logout/reboot.

# Per-UUID write counters driving periodic trims. Runtime-only, never persisted.
declare -gA KA_LOG_WRITES=()

# Role: Return the retained event-log line budget for one target.
ka_log_max_lines() {
    ka_tunable KEEPALIVE_LOG_MAX_LINES 2000
    printf '%s' "$REPLY"
}

# Role: Trim one runtime event log to its retention budget.
# Logs are append-only and the TUI loads a whole file into memory, so an unbounded
# history is a client hang as well as disk use.
ka_log_trim() {
    local path=$1 max tmp
    [[ -f $path ]] || return 0
    max=$(ka_log_max_lines)
    tmp="$path.trim.$$"
    if tail -n "$max" -- "$path" >"$tmp" 2>/dev/null; then
        mv -f -- "$tmp" "$path"
        chmod 600 "$path" 2>/dev/null || true
    else
        rm -f -- "$tmp"
    fi
    return 0
}

# Role: Return the runtime event-log path for a Konsole session UUID.
ka_log_path() {
    local uuid=$1
    printf '%s/%s.log' "$KA_LOGS_DIR" "$(ka_safe_id "$uuid")"
}

# Role: Append one tab-separated event to a target's independent runtime history.
ka_log_event() {
    local uuid=$1 event=$2 detail=${3-} result=${4-}
    local path
    path=$(ka_log_path "$uuid")
    mkdir -p "$KA_LOGS_DIR"
    printf '%s\t%s\t%s\t%s\n' "$(ka_now_hms)" "$(ka_single_line "$event")" \
        "$(ka_single_line "$detail")" "$(ka_single_line "$result")" >>"$path"
    chmod 600 "$path" 2>/dev/null || true
    local writes=$(( ${KA_LOG_WRITES[$uuid]:-0} + 1 ))
    KA_LOG_WRITES[$uuid]=$writes
    # Checking every write would fork `tail` per event; amortize it instead.
    local check_every
    ka_tunable KEEPALIVE_LOG_CHECK_EVERY 200
    check_every=$REPLY
    if ((writes % check_every == 0)); then
        ka_log_trim "$path"
    fi
    return 0
}

# Role: Delete a selected target's runtime history when the keep-alive is deleted.
ka_log_delete() {
    local uuid=$1
    rm -f -- "$(ka_log_path "$uuid")"
    unset 'KA_LOG_WRITES[$uuid]'
    return 0
}

# Role: Print the most recent N target events in chronological order for detail views.
ka_log_tail() {
    local uuid=$1 count=${2:-8} path
    path=$(ka_log_path "$uuid")
    [[ -r $path ]] || return 0
    tail -n "$count" "$path"
}

# Role: Print the complete event history for a target for the full log viewer.
ka_log_all() {
    local uuid=$1 path
    path=$(ka_log_path "$uuid")
    [[ -r $path ]] && cat -- "$path"
}
