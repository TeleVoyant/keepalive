#!/usr/bin/env bash
# Bash-friendly IPC built around a systemd-activated FIFO plus data-only request directories.
# The FIFO carries only small request IDs; arbitrary user messages never travel through it.

# Role: Return the filesystem directory for one client request identifier.
ka_ipc_request_dir() {
    printf '%s/%s' "$KA_REQUESTS_DIR" "$(ka_safe_id "$1")"
}

# Role: Return the filesystem directory for one daemon response identifier.
ka_ipc_response_dir() {
    printf '%s/%s' "$KA_RESPONSES_DIR" "$(ka_safe_id "$1")"
}

# Role: Ask systemd to ensure the per-user FIFO socket unit exists when installed.
ka_ipc_ensure_socket_unit() {
    [[ -p $KA_CONTROL_FIFO ]] && return 0
    if command -v systemctl >/dev/null 2>&1; then
        systemctl --user start keepalive.socket >/dev/null 2>&1 || true
    fi
    [[ -p $KA_CONTROL_FIFO ]]
}

# Role: Create a new private request directory and print its request identifier.
ka_ipc_new_request() {
    local command=$1 uuid=${2-} id dir
    ka_ensure_runtime_dirs
    id=$(ka_request_id)
    dir=$(ka_ipc_request_dir "$id")
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
    ka_write_scalar "$dir/command" "$command"
    [[ -n $uuid ]] && ka_write_scalar "$dir/uuid" "$uuid"
    printf '%s' "$id"
}

# Role: Notify the daemon that a completed request directory is ready for processing.
ka_ipc_signal_request() {
    local id=$1
    ka_ipc_ensure_socket_unit || {
        ka_error 'control FIFO is unavailable; install/enable keepalive.socket first'
        return 1
    }
    printf 'REQUEST %s\n' "$id" >"$KA_CONTROL_FIFO"
}

# Role: Wait for a request response and print "STATUS<TAB>message" to stdout.
ka_ipc_wait_response() {
    local id=$1 timeout_ms=${2:-8000} dir waited=0 status message
    dir=$(ka_ipc_response_dir "$id")
    while ((waited < timeout_ms)); do
        if [[ -r $dir/status ]]; then
            status=$(ka_read_first_line "$dir/status" ERROR)
            message=$(ka_read_first_line "$dir/message" '')
            printf '%s\t%s\n' "$status" "$message"
            rm -rf -- "$dir"
            return 0
        fi
        sleep 0.05
        ((waited += 50))
    done
    printf 'ERROR\tTimed out waiting for keepalive service\n'
    return 1
}

# Role: Submit a simple command request and wait synchronously for the daemon response.
ka_ipc_call() {
    local command=$1 uuid=${2-} id
    id=$(ka_ipc_new_request "$command" "$uuid") || return
    ka_ipc_signal_request "$id" || { rm -rf -- "$(ka_ipc_request_dir "$id")"; return 1; }
    ka_ipc_wait_response "$id"
}

# Role: Write a daemon response atomically for one client request.
ka_ipc_respond() {
    local id=$1 status=$2 message=${3-} dir
    dir=$(ka_ipc_response_dir "$id")
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
    ka_write_scalar "$dir/message" "$message"
    ka_write_scalar "$dir/status" "$status"
}

# Role: Open the control FIFO read/write so Bash can poll it without EOF busy-spinning.
ka_ipc_service_open() {
    ka_ensure_runtime_dirs
    if [[ ! -p $KA_CONTROL_FIFO ]]; then
        rm -f -- "$KA_CONTROL_FIFO"
        mkfifo -m 600 "$KA_CONTROL_FIFO"
    fi
    exec {KA_CONTROL_FD}<>"$KA_CONTROL_FIFO"
}

# Role: Read at most one FIFO control line with a short timeout for scheduler interleaving.
ka_ipc_service_read() {
    local timeout=${1:-0.20}
    IFS= read -r -t "$timeout" -u "$KA_CONTROL_FD" KA_IPC_LINE
}

# Role: Remove abandoned request/response directories older than the current service process session.
ka_ipc_cleanup_stale() {
    # Runtime state is private and short-lived. Keep cleanup conservative: only empty/finished
    # response/request directories older than one hour are removed when GNU find is available.
    command -v find >/dev/null 2>&1 || return 0
    find "$KA_REQUESTS_DIR" "$KA_RESPONSES_DIR" -mindepth 1 -maxdepth 1 -type d -mmin +60 \
        -exec rm -rf -- {} + 2>/dev/null || true
}

# Role: Dispatch one request directory to authoritative daemon state operations.
ka_ipc_handle_request() {
    local id=$1 dir command uuid rc=0 message='ok'
    dir=$(ka_ipc_request_dir "$id")
    [[ -d $dir ]] || { ka_ipc_respond "$id" ERROR 'request directory not found'; return 1; }
    command=$(ka_read_first_line "$dir/command")
    uuid=$(ka_read_first_line "$dir/uuid")
    # Validators record why they refused; start clean so a stale reason cannot leak
    # into an unrelated response.
    ka_error_reset

    case $command in
        PING)
            message='service online'
            ;;
        REFRESH)
            ka_state_refresh_discovery
            ka_state_validate_targets
            ka_state_publish_index
            message='refreshed'
            ;;
        CREATE)
            ka_state_create_target "$uuid" "$dir/config" || { rc=$?; message=${KA_LAST_ERROR:-'could not create keep-alive'}; }
            ;;
        CONFIGURE)
            ka_state_configure_target "$uuid" "$dir/config" || { rc=$?; message=${KA_LAST_ERROR:-'could not configure keep-alive'}; }
            ;;
        DELETE)
            ka_state_delete_target "$uuid" || { rc=$?; message=${KA_LAST_ERROR:-'keep-alive not found'}; }
            ;;
        TOGGLE_PAUSE)
            ka_state_toggle_pause "$uuid" || { rc=$?; message=${KA_LAST_ERROR:-'target cannot be paused/resumed'}; }
            ;;
        TOGGLE_MODE)
            ka_state_toggle_mode "$uuid" || { rc=$?; message=${KA_LAST_ERROR:-'delivery mode cannot be changed'}; }
            ;;
        RESET_MAIN)
            ka_state_reset_main "$uuid" || { rc=$?; message=${KA_LAST_ERROR:-'main timer cannot be reset'}; }
            ;;
        SEND_MAIN)
            ka_scheduler_send_main "$uuid" MANUAL || { rc=$?; message=${KA_LAST_ERROR:-'main send failed'}; }
            ;;
        SEND_SECONDARY)
            ka_scheduler_send_secondary "$uuid" MANUAL || { rc=$?; message=${KA_LAST_ERROR:-'secondary send failed'}; }
            ;;
        *)
            rc=2
            message="unknown command: $command"
            ;;
    esac

    ka_state_publish_index
    if ((rc == 0)); then
        ka_ipc_respond "$id" OK "$message"
    else
        ka_ipc_respond "$id" ERROR "$message"
    fi
    rm -rf -- "$dir"
    return "$rc"
}

# Role: Parse and dispatch one small FIFO line; malformed lines are ignored safely.
ka_ipc_handle_line() {
    local line=$1 verb id extra
    read -r verb id extra <<<"$line"
    [[ $verb == REQUEST && -n $id && -z $extra ]] || return 1
    [[ $id =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    ka_ipc_handle_request "$id"
}
