#!/usr/bin/env bash
# Konsole D-Bus discovery, identity validation, and input delivery.

# Role: List /Sessions/N object paths exported by one Konsole D-Bus service.
# Matching is done with builtin regexes: this runs for every Konsole service on every
# discovery pass, and the grep pipelines it replaced cost two or three processes each.
ka_konsole_session_paths() {
    local service=$1 xml output line node_re='<node name="([0-9]+)"' path_re='(/Sessions/[0-9]+)$'
    if ka_dbus_use_send; then
        xml=$(ka_dbus_send_scalar "$service" /Sessions org.freedesktop.DBus.Introspectable.Introspect 2>/dev/null) || return 0
        while [[ $xml =~ $node_re ]]; do
            printf '/Sessions/%s\n' "${BASH_REMATCH[1]}"
            xml=${xml#*"${BASH_REMATCH[0]}"}
        done
        return 0
    fi
    output=$(ka_qdbus_call "$service") || true
    while IFS= read -r line; do
        [[ $line =~ $path_re ]] && printf '%s\n' "${BASH_REMATCH[1]}"
    done <<<"$output"
    return 0
}

# Role: Fetch one scalar method from a Konsole session object.
ka_konsole_get() {
    local service=$1 path=$2 method=$3
    if ka_dbus_use_send; then
        ka_dbus_send_scalar "$service" "$path" "org.kde.konsole.Session.$method"
        return
    fi
    ka_qdbus_call "$service" "$path" "org.kde.konsole.Session.$method"
}

# Role: Put a human-readable command string for one process in REPLY.
ka_konsole_process_label_set() {
    local pid=$1 label=''
    ka_proc_cmdline_set "$pid" && label=$REPLY
    [[ -n $label ]] || { ka_proc_comm_set "$pid" && label=$REPLY; }
    [[ -n $label ]] || label='(unknown)'
    ka_strip_controls_set "$label"
}

# Role: Return a human-readable command string for one process.
ka_konsole_process_label() {
    ka_konsole_process_label_set "$1"
    printf '%s' "$REPLY"
}

# Role: Resolve a project display name from the AI process working-directory basename.
ka_konsole_session_name() {
    local ai_pid=$1 fgpid=$2 cwd=''
    if [[ $ai_pid =~ ^[0-9]+$ && -e /proc/$ai_pid/cwd ]]; then
        cwd=$(readlink "/proc/$ai_pid/cwd" 2>/dev/null || true)
    fi
    if [[ -z $cwd && $fgpid =~ ^[0-9]+$ && -e /proc/$fgpid/cwd ]]; then
        cwd=$(readlink "/proc/$fgpid/cwd" 2>/dev/null || true)
    fi
    [[ -n $cwd ]] || cwd='?'
    local name=${cwd##*/}
    [[ -n $name && $name != '?' ]] || name='unknown'
    local safe_name safe_cwd
    ka_single_line "$name"; safe_name=$REPLY
    ka_single_line "$cwd";  safe_cwd=$REPLY
    printf '%s\t%s\n' "$safe_name" "$safe_cwd"
}

# Role: Discover recognized AI CLI sessions across all live Konsole services into KA_DISCOVERY_ROWS.
# Each element is one TSV row - UUID, AI type, display name, cwd, service, path, terminal
# PID, foreground PID, AI PID, AI PID starttime, foreground command - and the last is the
# #COMPLETE or #INCOMPLETE marker. This runs in the caller's shell rather than behind a
# process substitution, so the classifier's per-process executable cache survives from
# one discovery pass to the next; in a child shell every pass started it empty.
ka_konsole_discover_rows() {
    local service path uuid term_pid fgpid class ai_type ai_pid ai_start name_info name cwd cmd row
    local budget deadline s_uuid s_type s_service s_path s_cmd
    KA_DISCOVERY_ROWS=()
    ka_tunable KEEPALIVE_DISCOVERY_BUDGET_MS 1000
    budget=$REPLY
    ka_now_ms
    deadline=$((REPLY + budget))
    while IFS= read -r service; do
        [[ -n $service ]] || continue
        while IFS= read -r path; do
            [[ -n $path ]] || continue
            # Each session costs up to three bounded D-Bus calls. Without a pass budget a
            # degraded bus blocks the whole daemon loop, which then exceeds the suspend
            # gap and silently stops advancing every countdown.
            ka_now_ms
            if ((REPLY > deadline)); then
                KA_DISCOVERY_ROWS+=('#INCOMPLETE')
                return 0
            fi
            uuid=$(ka_konsole_get "$service" "$path" shellSessionId 2>/dev/null || true)
            term_pid=$(ka_konsole_get "$service" "$path" processId 2>/dev/null || true)
            fgpid=$(ka_konsole_get "$service" "$path" foregroundProcessId 2>/dev/null || true)
            [[ -n $uuid && $term_pid =~ ^[0-9]+$ && $fgpid =~ ^[0-9]+$ ]] || continue

            ka_classifier_from_process_tree_set "$fgpid" 2>/dev/null || continue
            class=$REPLY
            ai_type=${class%%$'\t'*}
            ai_pid=${class#*$'\t'}
            ka_proc_starttime_set "$ai_pid" || continue
            ai_start=$REPLY

            name_info=$(ka_konsole_session_name "$ai_pid" "$fgpid")
            IFS=$'\t' read -r name cwd <<<"$name_info"
            ka_konsole_process_label_set "$fgpid"
            cmd=$REPLY
            ka_single_line "$uuid";     s_uuid=$REPLY
            ka_single_line "$ai_type";  s_type=$REPLY
            ka_single_line "$service";  s_service=$REPLY
            ka_single_line "$path";     s_path=$REPLY
            ka_single_line "$cmd";      s_cmd=$REPLY
            printf -v row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
                "$s_uuid" "$s_type" "$name" "$cwd" "$s_service" "$s_path" \
                "$term_pid" "$fgpid" "$ai_pid" "$ai_start" "$s_cmd"
            KA_DISCOVERY_ROWS+=("$row")
        done < <(ka_konsole_session_paths "$service")
    done < <(ka_qdbus_konsole_services)
    KA_DISCOVERY_ROWS+=('#COMPLETE')
}

# Role: Print one Konsole discovery pass, one TSV row per line, ending with its marker.
ka_konsole_discover() {
    ka_konsole_discover_rows
    printf '%s\n' "${KA_DISCOVERY_ROWS[@]}"
}

# Role: Verify that a target still refers to the exact original Konsole/AI process tree.
ka_konsole_validate_target() {
    local service=$1 path=$2 expected_uuid=$3 expected_term_pid=$4 expected_ai_pid=$5 expected_ai_start=$6
    local uuid term_pid fgpid start rc

    if uuid=$(ka_konsole_get "$service" "$path" shellSessionId 2>/dev/null); then :; else
        rc=$?
        ka_qdbus_status_is_timeout "$rc" && return 20
        # The call never completed, so it proves nothing about identity.
        return 21
    fi
    [[ $uuid == "$expected_uuid" ]] || return 10

    if term_pid=$(ka_konsole_get "$service" "$path" processId 2>/dev/null); then :; else
        rc=$?
        ka_qdbus_status_is_timeout "$rc" && return 20
        return 21
    fi
    [[ $term_pid == "$expected_term_pid" ]] || return 11

    [[ -d /proc/$expected_ai_pid ]] || return 12
    start=''
    ka_proc_starttime_set "$expected_ai_pid" && start=$REPLY
    [[ $start == "$expected_ai_start" ]] || return 13

    if fgpid=$(ka_konsole_get "$service" "$path" foregroundProcessId 2>/dev/null); then :; else
        rc=$?
        ka_qdbus_status_is_timeout "$rc" && return 20
        return 21
    fi
    [[ $fgpid =~ ^[0-9]+$ ]] || return 14
    ka_process_is_descendant_of "$fgpid" "$expected_ai_pid" || return 15
    return 0
}

# Role: Translate target-validation return codes into operator-facing reason text.
ka_konsole_validation_reason() {
    case ${1:-1} in
        10) printf 'Konsole session UUID no longer matches' ;;
        11) printf 'Konsole terminal process changed' ;;
        12) printf 'AI process exited' ;;
        13) printf 'AI PID was reused by another process' ;;
        14) printf 'Konsole foreground process is unavailable' ;;
        15) printf 'AI process no longer owns the foreground process tree' ;;
        20) printf 'Konsole D-Bus validation timed out' ;;
        21) printf 'Konsole D-Bus session could not be reached' ;;
        *)  printf 'Target validation failed' ;;
    esac
}

# Role: Identify target-validation failures that should not make identity sticky unavailable.
# A call that timed out (20) or could not be made at all (21) proves nothing about the
# target. Only a call that completed and returned a different value, or a local /proc
# check, is evidence of identity loss.
ka_konsole_validation_is_transient() {
    [[ ${1-} == 20 || ${1-} == 21 ]]
}

# Role: Send raw text to a specific Konsole session through its D-Bus sendText method.
ka_konsole_send_raw() {
    local service=$1 path=$2 text=$3
    ka_qdbus_call "$service" "$path" org.kde.konsole.Session.sendText "$text" >/dev/null
}

# Role: Deliver one keep-alive event in MESSAGE+ENTER or ENTER_ONLY mode.
#
# Returns 0 on success, 1 when nothing was delivered, 2 for an unknown mode, and 3 when
# the message reached the terminal but the submit did not. That last case is the
# duplicate-text hazard: a blind retry would append the message a second time. Callers
# record it and retry with submit_only so the pending line is completed, not repeated.
#
# KEEPALIVE_ATOMIC_SUBMIT=1 sends text and submit in a single sendText, which removes the
# partial state entirely. It is opt-in because some AI CLIs debounce input and may submit
# before rendering the text; that is why the gap exists.
ka_konsole_deliver() {
    local service=$1 path=$2 mode=$3 message=${4-} submit_only=${5:-0}
    local submit_seq=${KEEPALIVE_SUBMIT_SEQ:-$'\r'}
    # A duration, not an integer, so ka_tunable does not apply. It is handed to `sleep`,
    # where a malformed value would fail the pause between the message and its submit.
    local send_gap=${KEEPALIVE_SEND_GAP:-0.15}
    if [[ ! $send_gap =~ ^[0-9]+([.][0-9]+)?$ ]]; then
        ka_warn "KEEPALIVE_SEND_GAP=$send_gap is not a duration in seconds; using 0.15"
        send_gap=0.15
    elif [[ $send_gap =~ ^0*([0-9]+) ]] && ((10#${BASH_REMATCH[1]} >= 10)); then
        # A stop waits for the delivery in flight, and this gap sits inside it. Bounded
        # well below systemd's stop timeout so a graceful stop can never be cut short
        # into a SIGKILL between the text and its Enter.
        ka_warn "KEEPALIVE_SEND_GAP=$send_gap is too long; using the 10 second maximum"
        send_gap=10
    fi

    case $mode in
        ENTER_ONLY)
            ka_konsole_send_raw "$service" "$path" "$submit_seq" || return 1
            ;;
        MESSAGE_ENTER)
            if ((submit_only == 1)); then
                ka_konsole_send_raw "$service" "$path" "$submit_seq" || return 3
                return 0
            fi
            if [[ ${KEEPALIVE_ATOMIC_SUBMIT:-0} == 1 ]]; then
                ka_konsole_send_raw "$service" "$path" "$message$submit_seq" || return 1
                return 0
            fi
            ka_konsole_send_raw "$service" "$path" "$message" || return 1
            sleep "$send_gap"
            ka_konsole_send_raw "$service" "$path" "$submit_seq" || return 3
            ;;
        *)
            ka_error "unknown delivery mode: $mode"
            return 2
            ;;
    esac
    return 0
}
