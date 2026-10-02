#!/usr/bin/env bash
# Per-target event logging under the selected runtime base. Session-managed logs disappear
# at logout/reboot; the hardened /tmp fallback has a different physical lifecycle but is
# still non-durable application state.

# Per-UUID write counters driving periodic trims. Runtime-only, never persisted.
declare -gA KA_LOG_WRITES=() KA_LOG_WARNED=()

# Role: Return the retained event-log line budget for one target.
ka_log_max_lines() {
    ka_tunable KEEPALIVE_LOG_MAX_LINES 2000
    printf '%s' "$REPLY"
}

# Role: Warn once when one event-log path is unsafe, without breaking delivery.
ka_log_warn_once() {
    local path=$1 reason=$2
    if [[ -z ${KA_LOG_WARNED[$path]+x} ]]; then
        KA_LOG_WARNED[$path]=1
        ka_warn "skipping unsafe event log $path: $reason"
    fi
}

# Role: Validate the runtime log directory before opening a per-target log.
ka_log_directory_is_safe() {
    local canonical=$KA_LOGS_DIR
    [[ -d $canonical && ! -L $canonical && -O $canonical ]] || return 1
    canonical=$(readlink -f -- "$KA_LOGS_DIR") || return 1
    [[ $canonical == "$KA_LOGS_DIR" ]]
}

# Role: Close one held log descriptor and clear its shared register.
ka_log_close_fd() {
    local fd=${KA_LOG_FD:-}
    if [[ -n $fd ]]; then
        { exec {fd}>&-; } 2>/dev/null || true
    fi
    KA_LOG_FD=''
}

# Role: Open an owned regular event log for append without following a planted path.
# Existing logs are first opened read-write so a FIFO can never block the daemon; an
# append descriptor is then duplicated from that held inode through /dev/fd.
ka_log_open_append() {
    local path=$1 probe_fd append_fd fd created=0 rc=0 had_noclobber=0
    KA_LOG_FD=''
    [[ -L $path || (-e $path && ! -f $path) || (-e $path && ! -O $path) ]] && return 1
    if [[ ! -e $path ]]; then
        [[ $- == *C* ]] && had_noclobber=1
        set -o noclobber
        if { exec {fd}>"$path"; }; then
            created=1
        else
            rc=$?
        fi
        ((had_noclobber == 1)) || set +o noclobber
        ((created == 1)) || {
            [[ -e $path || -L $path ]] || return "$rc"
        }
    fi
    if ((created == 0)); then
        if ! exec {probe_fd}<>"$path"; then
            return 1
        fi
        if [[ ! -f /dev/fd/$probe_fd || -L $path || ! -O $path || ! $path -ef /dev/fd/$probe_fd ]]; then
            { exec {probe_fd}>&-; } 2>/dev/null || true
            return 1
        fi
        if ! exec {append_fd}>>"/dev/fd/$probe_fd"; then
            { exec {probe_fd}>&-; } 2>/dev/null || true
            return 1
        fi
        { exec {probe_fd}>&-; } 2>/dev/null || true
        fd=$append_fd
    fi
    if [[ ! -f /dev/fd/$fd || -L $path || ! -O $path || ! $path -ef /dev/fd/$fd ]]; then
        { exec {fd}>&-; } 2>/dev/null || true
        return 1
    fi
    chmod 600 "/dev/fd/$fd" 2>/dev/null || {
        { exec {fd}>&-; } 2>/dev/null || true
        return 1
    }
    KA_LOG_FD=$fd
}

# Role: Open an owned regular event log for a bounded trim read without blocking on FIFOs.
ka_log_open_read() {
    local path=$1 fd
    KA_LOG_FD=''
    [[ -f $path && ! -L $path && -O $path ]] || return 1
    if ! exec {fd}<>"$path"; then
        return 1
    fi
    if [[ ! -f /dev/fd/$fd || -L $path || ! -O $path || ! $path -ef /dev/fd/$fd ]]; then
        { exec {fd}>&-; } 2>/dev/null || true
        return 1
    fi
    KA_LOG_FD=$fd
}

# Role: Trim one runtime event log to its retention budget through held descriptors.
# Logs are append-only and the TUI loads a whole file into memory, so an unbounded
# history is a client hang as well as disk use. The temporary writer is O_EXCL and held
# by ka_atomic_temp, rather than a predictable path.trim.$$ redirection.
ka_log_trim() {
    local path=$1 max read_fd tmp
    [[ -f $path && ! -L $path && -O $path ]] || return 0
    max=$(ka_log_max_lines)
    ka_log_open_read "$path" || return 0
    read_fd=$KA_LOG_FD
    ka_atomic_temp "$KA_LOGS_DIR" "${path##*/}.trim" || { ka_log_close_fd; return 0; }
    tmp=$KA_ATOMIC_TMP
    if ! tail -n "$max" -- "/dev/fd/$read_fd" 2>/dev/null 1>&"$KA_ATOMIC_FD"; then
        ka_atomic_abort >/dev/null 2>&1 || true
        ka_log_close_fd
        return 0
    fi
    if ! ka_atomic_close; then
        ka_atomic_abort >/dev/null 2>&1 || true
        ka_log_close_fd
        return 0
    fi
    if [[ ! -f /dev/fd/$read_fd || -L $path || ! -O $path || ! $path -ef /dev/fd/$read_fd ]]; then
        rm -f -- "$tmp"
        ka_log_close_fd
        return 0
    fi
    ka_log_close_fd
    mv -fT -- "$tmp" "$path" || { rm -f -- "$tmp"; return 0; }
    chmod 600 "$path" 2>/dev/null || true
}

# Role: Return the runtime event-log path for a Konsole session UUID.
ka_log_path() {
    local uuid=$1
    ka_safe_id "$uuid"
    printf '%s/%s.log' "$KA_LOGS_DIR" "$REPLY"
}

# Role: Append one tab-separated event to a target's independent runtime history.
ka_log_event() {
    local uuid=$1 event=$2 detail=${3-} result=${4-}
    local path fd write_rc=0
    path=$(ka_log_path "$uuid")
    ka_log_directory_is_safe || { ka_log_warn_once "$path" 'log directory is not a private regular directory'; return 0; }
    local stamp s_event s_detail s_result
    printf -v stamp '%(%H:%M:%S)T' -1
    ka_single_line "$event";  s_event=$REPLY
    ka_single_line "$detail"; s_detail=$REPLY
    ka_single_line "$result"; s_result=$REPLY
    ka_log_open_append "$path" || { ka_log_warn_once "$path" 'log is not an owned regular file'; return 0; }
    fd=$KA_LOG_FD
    printf '%s\t%s\t%s\t%s\n' "$stamp" "$s_event" "$s_detail" "$s_result" >&"$fd" || write_rc=$?
    ka_log_close_fd
    if ((write_rc != 0)); then
        ka_log_warn_once "$path" 'event append failed'
        return 0
    fi
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
    local uuid=$1 path
    path=$(ka_log_path "$uuid")
    if [[ -e $path || -L $path ]]; then
        [[ -f $path && ! -L $path && -O $path ]] \
            || { ka_log_warn_once "$path" 'log is not an owned regular file'; return 0; }
        rm -f -- "$path" || ka_log_warn_once "$path" 'log removal failed'
    fi
    unset 'KA_LOG_WRITES[$uuid]'
    return 0
}

# Role: Print the most recent N target events in chronological order for detail views.
ka_log_tail() {
    local uuid=$1 count=${2:-8} path
    path=$(ka_log_path "$uuid")
    [[ -f $path && ! -L $path && -O $path && -r $path ]] || return 0
    tail -n "$count" "$path"
}

# Role: Print the complete event history for a target for the full log viewer.
ka_log_all() {
    local uuid=$1 path line time event detail result
    path=$(ka_log_path "$uuid")
    [[ -f $path && ! -L $path && -O $path && -r $path ]] || return 0
    while IFS= read -r line || [[ -n $line ]]; do
        # Keep the four trusted TSV separators for the TUI parser, but sanitize every
        # stored field before either this CLI sink or the full-log view sees it.
        if [[ $line != *$'\t'* ]]; then
            ka_sanitize_human_set "$line"
            printf '%s\n' "$REPLY"
            continue
        fi
        time=${line%%$'\t'*}; line=${line#*$'\t'}
        event=${line%%$'\t'*}; line=${line#*$'\t'}
        detail=${line%%$'\t'*}; result=${line#*$'\t'}
        ka_sanitize_human_set "$time"; time=$REPLY
        ka_sanitize_human_set "$event"; event=$REPLY
        ka_sanitize_human_set "$detail"; detail=$REPLY
        ka_sanitize_human_set "$result"; result=$REPLY
        printf '%s\t%s\t%s\t%s\n' "$time" "$event" "$detail" "$result"
    done <"$path"
}
