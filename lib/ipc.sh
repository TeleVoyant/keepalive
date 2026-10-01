#!/usr/bin/env bash
# Bash-friendly IPC built around a systemd-activated FIFO plus data-only request directories.
# The FIFO carries only small request IDs; arbitrary user messages never travel through it.

# Role: Return the filesystem directory for one client request identifier.
ka_ipc_request_dir() {
    ka_safe_id "$1"
    printf '%s/%s' "$KA_REQUESTS_DIR" "$REPLY"
}

# Role: Return the filesystem directory for one daemon response identifier.
ka_ipc_response_dir() {
    ka_safe_id "$1"
    printf '%s/%s' "$KA_RESPONSES_DIR" "$REPLY"
}

# Role: Validate and harden one owned real request or response directory.
ka_ipc_validate_private_dir() {
    local path=$1 canonical
    [[ -d $path && ! -L $path && -O $path ]] || return 1
    canonical=$(readlink -f -- "$path") || return 1
    [[ $canonical == "$path" ]] || return 1
    chmod 700 "$path" 2>/dev/null || return 1
}

# Role: Create one absent private IPC directory without following a planted symlink.
ka_ipc_create_private_dir() {
    local path=$1
    [[ ! -e $path && ! -L $path ]] || return 1
    mkdir -- "$path" || return 1
    ka_ipc_validate_private_dir "$path" || { rmdir -- "$path" 2>/dev/null || true; return 1; }
}

# Role: Create or validate the daemon's private response directory for one request.
ka_ipc_prepare_response_dir() {
    local path=$1
    if [[ ! -e $path && ! -L $path ]]; then
        mkdir -- "$path" || return 1
    fi
    ka_ipc_validate_private_dir "$path"
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
    KA_IPC_REQUEST_ID=''
    ka_ensure_runtime_dirs || return 1
    id=$(ka_request_id)
    dir=$(ka_ipc_request_dir "$id")
    ka_ipc_create_private_dir "$dir" \
        || { ka_error "could not create request directory: $dir"; return 1; }
    ka_write_scalar "$dir/command" "$command" \
        || { rm -rf -- "$dir"; ka_error 'could not write request command'; return 1; }
    if [[ -n $uuid ]]; then
        ka_write_scalar "$dir/uuid" "$uuid" \
            || { rm -rf -- "$dir"; ka_error 'could not write request target'; return 1; }
    fi
    # Operations that need one scalar argument put it in a data file, keeping the FIFO
    # line to just the request id.
    if [[ -n $value ]]; then
        ka_write_scalar "$dir/value" "$value" \
            || { rm -rf -- "$dir"; ka_error 'could not write request value'; return 1; }
    fi
    KA_IPC_REQUEST_ID=$id
    printf '%s' "$id"
}

# Role: Write one request notification to an already-open control descriptor.
ka_ipc_write_request_line() {
    local fd=$1 id=$2
    printf 'REQUEST %s\n' "$id" >&"$fd"
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
    if ! ka_ipc_write_request_line "$fd" "$id"; then
        { exec {fd}>&-; } 2>/dev/null || true
        ka_error "could not write to the control FIFO: $KA_CONTROL_FIFO"
        return 1
    fi
    if ! exec {fd}>&-; then
        ka_error "could not close the control FIFO: $KA_CONTROL_FIFO"
        return 1
    fi
}

# Role: Wait for a request response and print "STATUS<TAB>message" to stdout.
ka_ipc_wait_response() {
    # The default suits an idle desktop. A loaded machine, or a daemon working through a
    # slow bus, can legitimately take longer, and a spurious timeout looks to the operator
    # exactly like an unreachable service.
    local id=$1 timeout_ms=${2-} dir waited=0 status message step=10
    if [[ -z $timeout_ms ]]; then
        ka_tunable KEEPALIVE_RESPONSE_TIMEOUT_MS 8000
        timeout_ms=$REPLY
    fi
    ka_is_positive_int "$timeout_ms" || timeout_ms=8000
    dir=$(ka_ipc_response_dir "$id")
    # The daemon now wakes on the request at once, so most answers land within a few tens
    # of milliseconds: poll finely at first, then settle at the former 50 ms. Each poll is
    # a builtin test and a fork-free pause; the external sleep it replaces cost a process
    # per poll and padded every command with up to 50 ms of waiting.
    while ((waited < timeout_ms)); do
        if [[ -r $dir/status ]]; then
            status=ERROR
            [[ -r $dir/status ]] && { IFS= read -r status <"$dir/status" || true; }
            message=''
            [[ -r $dir/message ]] && { IFS= read -r message <"$dir/message" || true; }
            printf '%s\t%s\n' "$status" "$message"
            rm -rf -- "$dir"
            return 0
        fi
        ((waited >= 500)) && step=50
        printf -v REPLY '0.%03d' "$step"
        ka_sleep "$REPLY"
        ((waited += step))
    done
    printf 'ERROR\tTimed out waiting for keepalive service\n'
    return 1
}

# Role: Submit a simple command request and wait synchronously for the daemon response.
ka_ipc_call() {
    local command=$1 uuid=${2-} value=${3-} id
    ka_error_reset
    if ! ka_ipc_new_request "$command" "$uuid" "$value" >/dev/null; then
        printf 'ERROR\t%s\n' "${KA_LAST_ERROR:-could not create a request under $KA_REQUESTS_DIR}"
        return 1
    fi
    id=$KA_IPC_REQUEST_ID
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
    ka_ipc_prepare_response_dir "$dir" || return 1
    ka_write_scalar "$dir/message" "$message" || return 1
    ka_write_scalar "$dir/status" "$status"
}

# Role: Open the control FIFO read/write so Bash can poll it without EOF busy-spinning.
ka_ipc_service_open() {
    ka_ensure_runtime_dirs || return 1
    if [[ ! -p $KA_CONTROL_FIFO ]]; then
        rm -f -- "$KA_CONTROL_FIFO" || return 1
        mkfifo -m 600 "$KA_CONTROL_FIFO" || return 1
    fi
    exec {KA_CONTROL_FD}<>"$KA_CONTROL_FIFO"
}

# Role: Read at most one FIFO control line, separating an idle timeout from a broken read.
#
# Returns 0 with a line, 1 on the normal idle timeout, and 2 when the read failed for any
# other reason. That distinction matters because this read is the loop's only pacing: bash
# returns >128 when -t expires, but EOF or a bad descriptor returns immediately, which
# turns the daemon into a busy spin that never crashes and so never looks unhealthy.
ka_ipc_service_read() {
    local timeout=${1:-0.20} rc=0 rest=''
    KA_IPC_LINE=''
    IFS= read -r -t "$timeout" -u "$KA_CONTROL_FD" KA_IPC_LINE || rc=$?
    ((rc == 0)) && return 0
    if ((rc > 128)); then
        # A timeout can expire after the first bytes of a line were consumed: Bash then
        # reports the timeout but keeps that partial input in the variable. Treating it as
        # idle dropped the request and left the rest of the line to be rejected as garbage
        # on the next read - about one request in twenty once timer slack made the timeout
        # land late. Clients write each line in a single write, so the remainder is
        # already in the FIFO: finish the line instead.
        [[ -n $KA_IPC_LINE ]] || return 1
        rc=0
        IFS= read -r -t 1 -u "$KA_CONTROL_FD" rest || rc=$?
        KA_IPC_LINE+=$rest
        ((rc == 0)) && return 0
        ka_warn "discarded an incomplete control line"
        KA_IPC_LINE=''
        return 1
    fi
    return 2
}

# Role: Reopen the control FIFO after an abnormal read, replacing the old descriptor.
ka_ipc_service_reopen() {
    if [[ -n ${KA_CONTROL_FD:-} ]]; then
        { exec {KA_CONTROL_FD}>&-; } 2>/dev/null || true
    fi
    KA_CONTROL_FD=
    ka_ipc_service_open
}

# Role: Remove abandoned request/response directories older than the current service process session.
ka_ipc_cleanup_stale() {
    # Runtime state is private and short-lived. Only directories abandoned by a client that
    # died mid-request are swept, so the age threshold stays generous; the sweep itself runs
    # often enough that debris does not sit around for an hour.
    command -v find >/dev/null 2>&1 || return 0
    local age
    ka_tunable KEEPALIVE_STALE_REQUEST_MINUTES 30
    age=$REPLY
    find "$KA_REQUESTS_DIR" "$KA_RESPONSES_DIR" -mindepth 1 -maxdepth 1 -type d -mmin "+$age" \
        -exec rm -rf -- {} + 2>/dev/null || true
    return 0
}

# Role: Dispatch one request directory to authoritative daemon state operations.
ka_ipc_handle_request() {
    local id=$1 dir command uuid rc=0 publish_rc=0 response_rc=0 cleanup_rc=0 message='ok'
    dir=$(ka_ipc_request_dir "$id")
    if ! ka_ipc_validate_private_dir "$dir"; then
        ka_ipc_respond "$id" ERROR 'request directory not found' || response_rc=$?
        ((response_rc == 0)) || return "$response_rc"
        return 1
    fi
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

    ka_state_publish_index || publish_rc=$?
    if ((publish_rc != 0)); then
        if ((rc == 0)); then
            rc=$publish_rc
            message='could not publish the runtime index'
        else
            ka_warn "index publication also failed while handling $command (status $publish_rc)"
        fi
    fi
    if ((rc == 0)); then
        ka_ipc_respond "$id" OK "$message" || response_rc=$?
    else
        ka_ipc_respond "$id" ERROR "$message" || response_rc=$?
    fi
    rm -rf -- "$dir" || cleanup_rc=$?
    ((response_rc == 0)) || return "$response_rc"
    ((cleanup_rc == 0)) || return "$cleanup_rc"
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
