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
    local command=$1 uuid=${2-} value=${3-} id dir
    ka_ensure_runtime_dirs
    id=$(ka_request_id)
    dir=$(ka_ipc_request_dir "$id")
    mkdir -p "$dir"
    chmod 700 "$dir" 2>/dev/null || true
    ka_write_scalar "$dir/command" "$command"
    [[ -n $uuid ]] && ka_write_scalar "$dir/uuid" "$uuid"
    # Operations that need one scalar argument put it in a data file, keeping the FIFO
    # line to just the request id.
    [[ -n $value ]] && ka_write_scalar "$dir/value" "$value"
    printf '%s' "$id"
}

# Role: Notify the daemon that a completed request directory is ready for processing.
#
# The FIFO is opened read/write rather than write-only. Opening a FIFO for writing blocks
# until some process opens it for reading, so a FIFO left behind by a daemon that died -
# it creates its own when systemd did not, and RemoveOnStop only covers the socket unit's
# - would block the client forever with no output. An O_RDWR open never blocks, so a dead
# daemon now surfaces as the ordinary response timeout instead of a hang.
ka_ipc_signal_request() {
    local id=$1 fd
    ka_ipc_ensure_socket_unit || {
        ka_error "control FIFO is unavailable at $KA_CONTROL_FIFO; install/enable keepalive.socket first"
        return 1
    }
    if ! exec {fd}<>"$KA_CONTROL_FIFO"; then
        ka_error "could not open the control FIFO: $KA_CONTROL_FIFO"
        return 1
    fi
    printf 'REQUEST %s\n' "$id" >&"$fd"
    exec {fd}>&-
}

# Role: Wait for a request response and print "STATUS<TAB>message" to stdout.
ka_ipc_wait_response() {
    # The default suits an idle desktop. A loaded machine, or a daemon working through a
    # slow bus, can legitimately take longer, and a spurious timeout looks to the operator
    # exactly like an unreachable service.
    local id=$1 timeout_ms=${2:-${KEEPALIVE_RESPONSE_TIMEOUT_MS:-8000}} dir waited=0 status message
    ka_is_positive_int "$timeout_ms" || timeout_ms=8000
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
    local command=$1 uuid=${2-} value=${3-} id
    ka_error_reset
    if ! id=$(ka_ipc_new_request "$command" "$uuid" "$value"); then
        printf 'ERROR\t%s\n' "${KA_LAST_ERROR:-could not create a request under $KA_REQUESTS_DIR}"
        return 1
    fi
    if ! ka_ipc_signal_request "$id"; then
        rm -rf -- "$(ka_ipc_request_dir "$id")"
        # Callers print whatever follows the tab, so an unreachable daemon has to explain
        # itself here; it used to surface as "service unavailable:" with no reason at all.
        printf 'ERROR\t%s\n' "${KA_LAST_ERROR:-could not reach the keepalive service}"
        return 1
    fi
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
    # Runtime state is private and short-lived. Only directories abandoned by a client that
    # died mid-request are swept, so the age threshold stays generous; the sweep itself runs
    # often enough that debris does not sit around for an hour.
    command -v find >/dev/null 2>&1 || return 0
    local age=${KEEPALIVE_STALE_REQUEST_MINUTES:-30}
    ka_is_positive_int "$age" || age=30
    find "$KA_REQUESTS_DIR" "$KA_RESPONSES_DIR" -mindepth 1 -maxdepth 1 -type d -mmin "+$age" \
        -exec rm -rf -- {} + 2>/dev/null || true
    return 0
}

# Role: Dispatch one request directory to authoritative daemon state operations.
ka_ipc_handle_request() {
    local id=$1 dir command uuid rc=0 message='ok'
    dir=$(ka_ipc_request_dir "$id")
    [[ -d $dir ]] || { ka_ipc_respond "$id" ERROR 'request directory not found'; return 1; }
    command=$(ka_read_first_line "$dir/command")
    uuid=$(ka_read_first_line "$dir/uuid")
    local value
    value=$(ka_read_first_line "$dir/value")
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
        SET_MODE)
            ka_state_set_mode "$uuid" "$value" || { rc=$?; message=${KA_LAST_ERROR:-'delivery mode cannot be changed'}; }
            ;;
        SEND_ENTER)
            ka_scheduler_send_enter_once "$uuid" MANUAL || { rc=$?; message=${KA_LAST_ERROR:-'enter send failed'}; }
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
