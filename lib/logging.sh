#!/usr/bin/env bash
# Per-target runtime event logging. Logs intentionally live under XDG_RUNTIME_DIR
# and therefore do not survive a full logout/reboot.

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
}

# Role: Delete a selected target's runtime history when the keep-alive is deleted.
ka_log_delete() {
    local uuid=$1
    rm -f -- "$(ka_log_path "$uuid")"
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
