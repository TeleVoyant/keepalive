#!/usr/bin/env bash
# Authoritative daemon state for monitored targets and current Konsole discovery.
# Runtime state is data-only: no target/config file is ever sourced or eval'd.

# Role: Initialize all in-memory target and discovery collections used by the daemon.
ka_state_init_arrays() {
    declare -ga KA_T_UUIDS=()
    declare -gA KA_T_TYPE=() KA_T_NAME=() KA_T_DIR=() KA_T_SERVICE=() KA_T_PATH=()
    declare -gA KA_T_TERM_PID=() KA_T_AI_PID=() KA_T_AI_START=() KA_T_STATUS=()
    declare -gA KA_T_MODE=() KA_T_NOTIFY=() KA_T_MAIN_INTERVAL=() KA_T_MAIN_REMAIN=()
    declare -gA KA_T_MAIN_INDEX=() KA_T_SECONDARY_ENABLED=() KA_T_SECONDARY_INTERVAL=()
    declare -gA KA_T_SECONDARY_REMAIN=() KA_T_SECONDARY_MESSAGE=() KA_T_LAST_SEEN=()
    declare -gA KA_T_REASON=()
    # Consecutive transient validation failures. Runtime-only debounce, never persisted:
    # a checkpoint should not carry a grudge across a daemon restart.
    declare -gA KA_T_STRIKES=()
    # Set when a message reached the terminal but its submit did not. The next attempt
    # completes that pending line instead of appending the message again.
    declare -gA KA_T_PENDING_SUBMIT=()
    # The secondary prompt is a one-shot nudge: once it has fired for this arming it
    # stays quiet until the target is reconfigured.
    declare -gA KA_T_SECONDARY_DONE=()
    # Targets whose in-memory countdown has moved since their last checkpoint. Ticking a
    # countdown does not justify rewriting a whole record every second per target.
    declare -gA KA_T_DIRTY=()

    declare -ga KA_D_UUIDS=()
    declare -gA KA_D_TYPE=() KA_D_NAME=() KA_D_DIR=() KA_D_SERVICE=() KA_D_PATH=()
    declare -gA KA_D_TERM_PID=() KA_D_FG_PID=() KA_D_AI_PID=() KA_D_AI_START=() KA_D_CMD=()
}

# Role: Put the private runtime directory for one monitored target in REPLY.
ka_state_target_dir() {
    ka_safe_id "$1"
    REPLY="$KA_TARGETS_DIR/$REPLY"
}

# Role: Return true when the daemon currently has a monitored record for a UUID.
ka_state_has_target() {
    local uuid=$1
    [[ -n ${KA_T_STATUS[$uuid]+x} ]]
}

# Role: Add one UUID to the target-order array when it is not already present.
ka_state_register_uuid() {
    local uuid=$1 existing
    for existing in "${KA_T_UUIDS[@]}"; do
        [[ $existing == "$uuid" ]] && return 0
    done
    KA_T_UUIDS+=("$uuid")
}

# Role: Remove one UUID from the target-order array without disturbing other targets.
ka_state_unregister_uuid() {
    local uuid=$1 item
    local -a next=()
    for item in "${KA_T_UUIDS[@]}"; do
        [[ $item == "$uuid" ]] || next+=("$item")
    done
    KA_T_UUIDS=("${next[@]}")
}

# Role: Note that a target's in-memory state has moved ahead of its checkpoint.
ka_state_mark_dirty() {
    KA_T_DIRTY[$1]=1
}

# Role: Checkpoint every target whose countdown has moved since the last flush.
#
# Countdown decrements used to be checkpointed on every tick, which rewrote a full record
# per target per second purely to persist a decremented number. Recovery already treats
# daemon downtime as a preserved gap, so a periodic flush loses nothing that matters:
# the worst case is a countdown that resumes at most one flush interval stale.
ka_state_flush_dirty() {
    local uuid
    for uuid in "${!KA_T_DIRTY[@]}"; do
        ka_state_has_target "$uuid" || { unset 'KA_T_DIRTY[$uuid]'; continue; }
        ka_state_save_target "$uuid" || true
    done
    return 0
}

# Role: Append one sanitized key/value row to the checkpoint payload being built.
# Kept as a helper so every field is written the same way and nothing forks per field.
ka_state_payload_row() {
    ka_single_line "$2"
    KA_STATE_PAYLOAD+="$1"$'\t'"$REPLY"$'\n'
}

# Role: Save one monitored target's mutable scalar state using atomic file replacement.
ka_state_save_target() {
    local uuid=$1 dir file
    ka_state_target_dir "$uuid"; dir=$REPLY
    # Created once, not re-made and re-chmodded on every checkpoint; both were forks on a
    # path that runs for every target on every flush.
    if [[ ! -d $dir/messages ]]; then
        mkdir -p "$dir/messages"
        chmod 700 "$dir" "$dir/messages" 2>/dev/null || true
    fi
    file="$dir/state.tsv"
    KA_STATE_PAYLOAD=''
    ka_state_payload_row uuid                "$uuid"
    ka_state_payload_row type                "${KA_T_TYPE[$uuid]}"
    ka_state_payload_row name                "${KA_T_NAME[$uuid]}"
    ka_state_payload_row directory           "${KA_T_DIR[$uuid]}"
    ka_state_payload_row service             "${KA_T_SERVICE[$uuid]}"
    ka_state_payload_row path                "${KA_T_PATH[$uuid]}"
    ka_state_payload_row term_pid            "${KA_T_TERM_PID[$uuid]}"
    ka_state_payload_row ai_pid              "${KA_T_AI_PID[$uuid]}"
    ka_state_payload_row ai_start            "${KA_T_AI_START[$uuid]}"
    ka_state_payload_row status              "${KA_T_STATUS[$uuid]}"
    ka_state_payload_row mode                "${KA_T_MODE[$uuid]}"
    ka_state_payload_row notifications       "${KA_T_NOTIFY[$uuid]}"
    ka_state_payload_row main_interval       "${KA_T_MAIN_INTERVAL[$uuid]}"
    ka_state_payload_row main_remaining      "${KA_T_MAIN_REMAIN[$uuid]}"
    ka_state_payload_row main_index          "${KA_T_MAIN_INDEX[$uuid]}"
    ka_state_payload_row secondary_enabled   "${KA_T_SECONDARY_ENABLED[$uuid]}"
    ka_state_payload_row secondary_interval  "${KA_T_SECONDARY_INTERVAL[$uuid]}"
    ka_state_payload_row secondary_remaining "${KA_T_SECONDARY_REMAIN[$uuid]}"
    ka_state_payload_row secondary_done      "${KA_T_SECONDARY_DONE[$uuid]:-0}"
    ka_state_payload_row last_seen           "${KA_T_LAST_SEEN[$uuid]-}"
    ka_state_payload_row reason              "${KA_T_REASON[$uuid]-}"
    ka_atomic_write_value "$file" "$KA_STATE_PAYLOAD"
    unset 'KA_T_DIRTY[$uuid]'
    ka_atomic_write_value "$dir/secondary_message" "${KA_T_SECONDARY_MESSAGE[$uuid]-}"
}

# Role: Record a precise checkpoint-validation failure for quarantine diagnostics.
ka_state_load_reject() {
    KA_STATE_LOAD_ERROR=$1
    return 1
}

# Role: Load and fully validate one persisted runtime target without executing data.
ka_state_load_target_dir() {
    # Split deliberately: bash expands every assignment word in one `local` before
    # creating any of them, so `local dir=$1 file="$dir/..."` reads an outer `dir` and
    # fails outright under `set -u` when no outer one exists.
    local dir=$1
    local file="$dir/state.tsv"
    KA_STATE_LOAD_ERROR=''
    [[ -f $file && ! -L $file ]] || { ka_state_load_reject 'state.tsv is missing or not a regular file'; return 1; }
    local key value extra uuid=''
    local type='' name='' directory='' service='' path='' term_pid='' ai_pid='' ai_start=''
    local status='' mode='' notifications='' main_interval='' main_remaining='' main_index=''
    local secondary_enabled='' secondary_interval='' secondary_remaining='' last_seen='' reason=''
    local secondary_done=''
    local parse_error='' secondary_message='' message_count=0 safe_uuid=''
    local -A seen=()

    while IFS=$'\t' read -r key value extra; do
        case $key in
            uuid|type|name|directory|service|path|term_pid|ai_pid|ai_start|status|mode|notifications|main_interval|main_remaining|main_index|secondary_enabled|secondary_interval|secondary_remaining|secondary_done|last_seen|reason)
                if [[ -n ${seen[$key]+x} ]]; then
                    parse_error="duplicate state field: $key"
                    continue
                fi
                if [[ -n $extra ]]; then
                    parse_error="unexpected extra columns in state field: $key"
                    continue
                fi
                seen[$key]=1
                ;;
            *) continue ;;
        esac
        case $key in
            uuid) uuid=$value ;;
            type) type=$value ;;
            name) name=$value ;;
            directory) directory=$value ;;
            service) service=$value ;;
            path) path=$value ;;
            term_pid) term_pid=$value ;;
            ai_pid) ai_pid=$value ;;
            ai_start) ai_start=$value ;;
            status) status=$value ;;
            mode) mode=$value ;;
            notifications) notifications=$value ;;
            main_interval) main_interval=$value ;;
            main_remaining) main_remaining=$value ;;
            main_index) main_index=$value ;;
            secondary_enabled) secondary_enabled=$value ;;
            secondary_interval) secondary_interval=$value ;;
            secondary_remaining) secondary_remaining=$value ;;
            secondary_done) secondary_done=$value ;;
            last_seen) last_seen=$value ;;
            reason) reason=$value ;;
        esac
    done <"$file"

    [[ -z $parse_error ]] || { ka_state_load_reject "$parse_error"; return 1; }
    local required
    for required in uuid type name directory service path term_pid ai_pid ai_start status mode notifications \
        main_interval main_remaining main_index secondary_enabled secondary_interval secondary_remaining last_seen reason; do
        [[ -n ${seen[$required]+x} ]] || { ka_state_load_reject "missing state field: $required"; return 1; }
    done

    [[ -n $uuid && ${#uuid} -le 256 ]] || { ka_state_load_reject 'uuid is empty or unreasonably long'; return 1; }
    ka_safe_id "$uuid"; safe_uuid=$REPLY
    [[ ${dir##*/} == "$safe_uuid" ]] || { ka_state_load_reject 'target directory does not match stored uuid'; return 1; }
    [[ -n $type && -n $name && -n $directory ]] || { ka_state_load_reject 'type, name, and directory are required'; return 1; }
    [[ $service =~ ^org\.kde\.konsole(-[0-9]+)?$ ]] || { ka_state_load_reject 'invalid Konsole D-Bus service'; return 1; }
    [[ $path =~ ^/Sessions/[0-9]+$ ]] || { ka_state_load_reject 'invalid Konsole session path'; return 1; }
    ka_is_positive_int "$term_pid" || { ka_state_load_reject 'term_pid must be positive'; return 1; }
    ka_is_positive_int "$ai_pid" || { ka_state_load_reject 'ai_pid must be positive'; return 1; }
    ka_is_positive_int "$ai_start" || { ka_state_load_reject 'ai_start must be positive'; return 1; }
    [[ $status == ACTIVE || $status == PAUSED || $status == UNAVAILABLE ]] || { ka_state_load_reject 'invalid target status'; return 1; }
    [[ $mode == MESSAGE_ENTER || $mode == ENTER_ONLY ]] || { ka_state_load_reject 'invalid delivery mode'; return 1; }
    [[ $notifications == 0 || $notifications == 1 ]] || { ka_state_load_reject 'notifications must be 0 or 1'; return 1; }
    [[ $secondary_enabled == 0 || $secondary_enabled == 1 ]] || { ka_state_load_reject 'secondary_enabled must be 0 or 1'; return 1; }
    ka_is_positive_int "$main_interval" || { ka_state_load_reject 'main_interval must be positive'; return 1; }
    ka_is_uint "$main_remaining" || { ka_state_load_reject 'main_remaining must be unsigned'; return 1; }
    ((main_remaining <= main_interval)) || { ka_state_load_reject 'main_remaining exceeds main_interval'; return 1; }
    ka_is_uint "$main_index" || { ka_state_load_reject 'main_index must be unsigned'; return 1; }
    ka_is_positive_int "$secondary_interval" || { ka_state_load_reject 'secondary_interval must be positive'; return 1; }
    ka_is_uint "$secondary_remaining" || { ka_state_load_reject 'secondary_remaining must be unsigned'; return 1; }
    ((secondary_remaining <= secondary_interval)) || { ka_state_load_reject 'secondary_remaining exceeds secondary_interval'; return 1; }
    # Optional on purpose: checkpoints written before this field existed must still load.
    [[ -z $secondary_done || $secondary_done == 0 || $secondary_done == 1 ]] || {
        ka_state_load_reject 'secondary_done must be 0 or 1'
        return 1
    }
    [[ -f $dir/secondary_message && ! -L $dir/secondary_message ]] || {
        ka_state_load_reject 'secondary_message is missing or not a regular file'
        return 1
    }
    secondary_message=$(cat -- "$dir/secondary_message") || { ka_state_load_reject 'secondary_message could not be read'; return 1; }
    if [[ $secondary_enabled == 1 ]]; then
        [[ -n $secondary_message && $secondary_message != *$'\n'* ]] || {
            ka_state_load_reject 'enabled secondary_message must be one non-empty logical line'
            return 1
        }
    fi
    ka_profile_validate_main_messages "$dir/messages" >/dev/null 2>&1 || {
        ka_state_load_reject 'main message rotation is not contiguous non-empty 001..N'
        return 1
    }
    message_count=$(ka_state_message_count "$uuid")
    ((main_index < message_count)) || { ka_state_load_reject 'main_index exceeds message rotation'; return 1; }

    ka_state_register_uuid "$uuid"
    KA_T_TYPE[$uuid]=$type
    KA_T_NAME[$uuid]=$name
    KA_T_DIR[$uuid]=$directory
    KA_T_SERVICE[$uuid]=$service
    KA_T_PATH[$uuid]=$path
    KA_T_TERM_PID[$uuid]=$term_pid
    KA_T_AI_PID[$uuid]=$ai_pid
    KA_T_AI_START[$uuid]=$ai_start
    KA_T_STATUS[$uuid]=$status
    KA_T_MODE[$uuid]=$mode
    KA_T_NOTIFY[$uuid]=$notifications
    KA_T_MAIN_INTERVAL[$uuid]=$main_interval
    KA_T_MAIN_REMAIN[$uuid]=$main_remaining
    KA_T_MAIN_INDEX[$uuid]=$main_index
    KA_T_SECONDARY_ENABLED[$uuid]=$secondary_enabled
    KA_T_SECONDARY_INTERVAL[$uuid]=$secondary_interval
    KA_T_SECONDARY_REMAIN[$uuid]=$secondary_remaining
    KA_T_SECONDARY_DONE[$uuid]=${secondary_done:-0}
    KA_T_SECONDARY_MESSAGE[$uuid]=$secondary_message
    KA_T_LAST_SEEN[$uuid]=$last_seen
    KA_T_REASON[$uuid]=$reason
    KA_T_STRIKES[$uuid]=0
    KA_T_PENDING_SUBMIT[$uuid]=0
}

# Role: Move a malformed runtime record out of active targets and preserve its reason.
ka_state_quarantine_target_dir() {
    local source=$1 reason=$2 base safe_base destination log
    base=${source##*/}
    ka_safe_id "$base"; safe_base=$REPLY
    [[ -n $safe_base ]] || safe_base=target
    if ! destination=$(mktemp -d "$KA_QUARANTINE_DIR/${safe_base}.XXXXXXXX"); then
        ka_warn "could not create quarantine destination for: $source"
        return 1
    fi
    chmod 700 "$destination" 2>/dev/null || true
    if ! mv -- "$source" "$destination/record"; then
        rmdir -- "$destination" 2>/dev/null || true
        ka_warn "could not quarantine invalid runtime target record: $source"
        return 1
    fi
    ka_write_scalar "$destination/quarantine_reason" "$reason"
    ka_write_scalar "$destination/quarantined_at" "$(ka_now_full)"
    log="$KA_LOGS_DIR/$base.log"
    if [[ -e $log || -L $log ]]; then
        mv -- "$log" "$destination/events.log" || ka_warn "could not preserve quarantined event log: $log"
    fi
    ka_warn "quarantined invalid runtime target record $base: $reason"
}

# Role: Restore valid runtime targets and quarantine malformed records with reasons.
ka_state_load_all_targets() {
    local dir reason had_nullglob=0 had_dotglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -q dotglob && had_dotglob=1
    shopt -s nullglob dotglob
    for dir in "$KA_TARGETS_DIR"/*; do
        if [[ ! -d $dir || -L $dir ]]; then
            ka_state_quarantine_target_dir "$dir" 'target entry is not a regular directory' || true
            continue
        fi
        if ka_state_load_target_dir "$dir"; then
            :
        else
            reason=${KA_STATE_LOAD_ERROR:-'unknown checkpoint validation failure'}
            ka_state_quarantine_target_dir "$dir" "$reason" || true
        fi
    done
    ((had_nullglob == 1)) || shopt -u nullglob
    ((had_dotglob == 1)) || shopt -u dotglob
}

# Role: Rebuild the discovery snapshot, committing only a complete pass.
ka_state_refresh_discovery() {
    local -a n_uuids=()
    local -A n_type=() n_name=() n_dir=() n_service=() n_path=()
    local -A n_term=() n_fg=() n_ai=() n_start=() n_cmd=()
    local complete=0 uuid type name directory service path term_pid fgpid ai_pid ai_start cmd key

    while IFS=$'\t' read -r uuid type name directory service path term_pid fgpid ai_pid ai_start cmd; do
        case $uuid in
            '#COMPLETE') complete=1; continue ;;
            '#INCOMPLETE') complete=0; continue ;;
            '') continue ;;
        esac
        n_uuids+=("$uuid")
        n_type[$uuid]=$type; n_name[$uuid]=$name; n_dir[$uuid]=$directory
        n_service[$uuid]=$service; n_path[$uuid]=$path; n_term[$uuid]=$term_pid
        n_fg[$uuid]=$fgpid; n_ai[$uuid]=$ai_pid; n_start[$uuid]=$ai_start; n_cmd[$uuid]=$cmd
    done < <(ka_konsole_discover)

    # A truncated pass would look like sessions disappearing, so keep the previous
    # snapshot and let the caller decide whether to warn.
    if ((complete != 1)); then
        KA_DISCOVERY_STALE=1
        return 1
    fi
    KA_DISCOVERY_STALE=0
    ka_now_monotonic && KA_DISCOVERY_STAMP=$REPLY

    KA_D_UUIDS=()
    KA_D_TYPE=() KA_D_NAME=() KA_D_DIR=() KA_D_SERVICE=() KA_D_PATH=()
    KA_D_TERM_PID=() KA_D_FG_PID=() KA_D_AI_PID=() KA_D_AI_START=() KA_D_CMD=()
    for key in "${n_uuids[@]}"; do
        KA_D_UUIDS+=("$key")
        KA_D_TYPE[$key]=${n_type[$key]}; KA_D_NAME[$key]=${n_name[$key]}; KA_D_DIR[$key]=${n_dir[$key]}
        KA_D_SERVICE[$key]=${n_service[$key]}; KA_D_PATH[$key]=${n_path[$key]}
        KA_D_TERM_PID[$key]=${n_term[$key]}; KA_D_FG_PID[$key]=${n_fg[$key]}
        KA_D_AI_PID[$key]=${n_ai[$key]}; KA_D_AI_START[$key]=${n_start[$key]}; KA_D_CMD[$key]=${n_cmd[$key]}
    done
    return 0
}

# Role: Copy a validated wizard request's message rotation into a target runtime directory.
ka_state_copy_request_messages() {
    local request_dir=$1 target_dir=$2 staged="$2/messages.staged.$$"
    rm -rf -- "$staged"
    mkdir -p "$staged" || return 1
    chmod 700 "$staged" 2>/dev/null || true
    cp -f -- "$request_dir/messages"/[0-9][0-9][0-9] "$staged/" || { rm -rf -- "$staged"; return 1; }
    chmod 600 "$staged"/* 2>/dev/null || true
    ka_commit_staged_dir "$staged" "$target_dir/messages"
}

# Role: Count non-empty stored main messages for one monitored target.
ka_state_message_count() {
    local uuid=$1 dir file count=0
    ka_state_target_dir "$uuid"; dir=$REPLY
    shopt -s nullglob
    for file in "$dir/messages"/[0-9][0-9][0-9]; do
        [[ -s $file ]] && ((count += 1))
    done
    shopt -u nullglob
    printf '%d' "$count"
}

# Role: Return one zero-based message by rotation index for a monitored target.
ka_state_message_at() {
    local uuid=$1 index=$2 dir file number
    ka_state_target_dir "$uuid"; dir=$REPLY
    number=$((index + 1))
    printf -v file '%s/messages/%03d' "$dir" "$number"
    [[ -r $file ]] || return 1
    cat -- "$file"
}

# Role: Create a new ACTIVE keep-alive from a currently AVAILABLE discovered session.
ka_state_create_target() {
    local uuid=$1 request_dir=$2
    ka_state_has_target "$uuid" && { ka_error 'target already has a keep-alive'; return 1; }
    [[ -n ${KA_D_TYPE[$uuid]+x} ]] || { ka_error 'selected Konsole session is no longer available'; return 1; }
    ka_profile_validate_request "$request_dir" || return 1

    local target_dir main_interval secondary_interval
    ka_state_target_dir "$uuid"; target_dir=$REPLY
    mkdir -p "$target_dir"
    main_interval=$(ka_read_first_line "$request_dir/main_interval")
    secondary_interval=$(ka_read_first_line "$request_dir/secondary_interval")

    ka_state_register_uuid "$uuid"
    KA_T_TYPE[$uuid]=${KA_D_TYPE[$uuid]}
    KA_T_NAME[$uuid]=${KA_D_NAME[$uuid]}
    KA_T_DIR[$uuid]=${KA_D_DIR[$uuid]}
    KA_T_SERVICE[$uuid]=${KA_D_SERVICE[$uuid]}
    KA_T_PATH[$uuid]=${KA_D_PATH[$uuid]}
    KA_T_TERM_PID[$uuid]=${KA_D_TERM_PID[$uuid]}
    KA_T_AI_PID[$uuid]=${KA_D_AI_PID[$uuid]}
    KA_T_AI_START[$uuid]=${KA_D_AI_START[$uuid]}
    KA_T_STATUS[$uuid]=ACTIVE
    KA_T_MODE[$uuid]=$(ka_read_first_line "$request_dir/delivery_mode")
    KA_T_NOTIFY[$uuid]=$(ka_read_first_line "$request_dir/notifications")
    KA_T_MAIN_INTERVAL[$uuid]=$main_interval
    KA_T_MAIN_REMAIN[$uuid]=$main_interval
    KA_T_MAIN_INDEX[$uuid]=0
    KA_T_SECONDARY_ENABLED[$uuid]=$(ka_read_first_line "$request_dir/secondary_enabled")
    KA_T_SECONDARY_INTERVAL[$uuid]=$secondary_interval
    KA_T_SECONDARY_REMAIN[$uuid]=$secondary_interval
    KA_T_SECONDARY_MESSAGE[$uuid]=$(cat "$request_dir/secondary_message")
    KA_T_LAST_SEEN[$uuid]=$(ka_now_full)
    KA_T_REASON[$uuid]=''
    KA_T_STRIKES[$uuid]=0
    KA_T_PENDING_SUBMIT[$uuid]=0
    KA_T_SECONDARY_DONE[$uuid]=0

    ka_state_copy_request_messages "$request_dir" "$target_dir"
    ka_state_save_target "$uuid"
    ka_profile_update_from_request "$request_dir"
    ka_log_event "$uuid" CREATED "${KA_T_TYPE[$uuid]} / ${KA_T_NAME[$uuid]}" ACTIVE
}

# Role: Reconfigure one existing available target and update the single global profile.
# Applying configuration deliberately resets that target's main/secondary countdowns.
ka_state_configure_target() {
    local uuid=$1 request_dir=$2
    ka_state_has_target "$uuid" || { ka_error 'unknown keep-alive target'; return 1; }
    [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || { ka_error 'unavailable targets cannot be reconfigured'; return 1; }
    ka_profile_validate_request "$request_dir" || return 1

    local target_dir
    ka_state_target_dir "$uuid"; target_dir=$REPLY
    KA_T_MODE[$uuid]=$(ka_read_first_line "$request_dir/delivery_mode")
    KA_T_NOTIFY[$uuid]=$(ka_read_first_line "$request_dir/notifications")
    KA_T_MAIN_INTERVAL[$uuid]=$(ka_read_first_line "$request_dir/main_interval")
    KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
    KA_T_MAIN_INDEX[$uuid]=0
    KA_T_SECONDARY_ENABLED[$uuid]=$(ka_read_first_line "$request_dir/secondary_enabled")
    KA_T_SECONDARY_INTERVAL[$uuid]=$(ka_read_first_line "$request_dir/secondary_interval")
    KA_T_SECONDARY_REMAIN[$uuid]=${KA_T_SECONDARY_INTERVAL[$uuid]}
    # Reconfiguring re-arms the one-shot nudge along with the countdowns.
    KA_T_SECONDARY_DONE[$uuid]=0
    KA_T_SECONDARY_MESSAGE[$uuid]=$(cat "$request_dir/secondary_message")
    ka_state_copy_request_messages "$request_dir" "$target_dir"
    ka_state_save_target "$uuid"
    ka_profile_update_from_request "$request_dir"
    ka_log_event "$uuid" CONFIG 'configuration updated; countdowns reset' OK
}

# Role: Permanently remove one keep-alive runtime record and its independent event history.
ka_state_delete_target() {
    local uuid=$1 dir
    ka_state_has_target "$uuid" || return 1
    ka_state_target_dir "$uuid"; dir=$REPLY
    rm -rf -- "$dir"
    ka_log_delete "$uuid"
    ka_state_unregister_uuid "$uuid"
    unset 'KA_T_TYPE[$uuid]' 'KA_T_NAME[$uuid]' 'KA_T_DIR[$uuid]' 'KA_T_SERVICE[$uuid]'
    unset 'KA_T_PATH[$uuid]' 'KA_T_TERM_PID[$uuid]' 'KA_T_AI_PID[$uuid]' 'KA_T_AI_START[$uuid]'
    unset 'KA_T_STATUS[$uuid]' 'KA_T_MODE[$uuid]' 'KA_T_NOTIFY[$uuid]' 'KA_T_MAIN_INTERVAL[$uuid]'
    unset 'KA_T_MAIN_REMAIN[$uuid]' 'KA_T_MAIN_INDEX[$uuid]' 'KA_T_SECONDARY_ENABLED[$uuid]'
    unset 'KA_T_SECONDARY_INTERVAL[$uuid]' 'KA_T_SECONDARY_REMAIN[$uuid]' 'KA_T_SECONDARY_MESSAGE[$uuid]'
    unset 'KA_T_LAST_SEEN[$uuid]' 'KA_T_REASON[$uuid]' 'KA_T_STRIKES[$uuid]' 'KA_T_DIRTY[$uuid]'
    unset 'KA_T_PENDING_SUBMIT[$uuid]' 'KA_T_SECONDARY_DONE[$uuid]'
}

# Role: Toggle ACTIVE/PAUSED while preserving each countdown exactly.
ka_state_toggle_pause() {
    local uuid=$1
    ka_state_has_target "$uuid" || return 1
    case ${KA_T_STATUS[$uuid]} in
        ACTIVE)
            KA_T_STATUS[$uuid]=PAUSED
            ka_log_event "$uuid" STATE paused PAUSED
            ;;
        PAUSED)
            KA_T_STATUS[$uuid]=ACTIVE
            ka_log_event "$uuid" STATE resumed ACTIVE
            ;;
        *)
            return 2
            ;;
    esac
    ka_state_save_target "$uuid"
}

# Role: Toggle the whole target between MESSAGE+ENTER and ENTER_ONLY delivery.
ka_state_toggle_mode() {
    local uuid=$1 old new
    ka_state_has_target "$uuid" || return 1
    [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || return 2
    old=${KA_T_MODE[$uuid]}
    if [[ $old == MESSAGE_ENTER ]]; then new=ENTER_ONLY; else new=MESSAGE_ENTER; fi
    KA_T_MODE[$uuid]=$new
    ka_state_save_target "$uuid"
    ka_log_event "$uuid" MODE "$old -> $new" OK
}

# Role: Set one target's delivery mode explicitly rather than toggling it.
# The detail view needs to *reach* a mode, not flip whichever way it happens to be:
# `e` returns to MESSAGE_ENTER and `E` pins ENTER_ONLY.
ka_state_set_mode() {
    local uuid=$1 mode=$2 old
    ka_state_has_target "$uuid" || { ka_error 'unknown keep-alive target'; return 1; }
    [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || { ka_error 'unavailable targets cannot change delivery mode'; return 2; }
    [[ $mode == MESSAGE_ENTER || $mode == ENTER_ONLY ]] || { ka_error "invalid delivery mode: $mode"; return 2; }
    old=${KA_T_MODE[$uuid]}
    [[ $old != "$mode" ]] || return 0
    KA_T_MODE[$uuid]=$mode
    ka_state_save_target "$uuid"
    ka_log_event "$uuid" MODE "$old -> $mode" OK
}

# Role: Reset only the selected target's main countdown to its configured interval.
ka_state_reset_main() {
    local uuid=$1
    ka_state_has_target "$uuid" || return 1
    [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || return 2
    KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
    ka_state_save_target "$uuid"
    ka_log_event "$uuid" TIMER 'main timer reset' OK
}

# Role: Transition a target to sticky UNAVAILABLE state while retaining all state/logs.
ka_state_mark_unavailable() {
    local uuid=$1 reason=$2 previous
    ka_state_has_target "$uuid" || return 1
    previous=${KA_T_STATUS[$uuid]}
    [[ $previous == UNAVAILABLE ]] && return 0
    KA_T_STATUS[$uuid]=UNAVAILABLE
    KA_T_REASON[$uuid]=$reason
    KA_T_STRIKES[$uuid]=0
    KA_T_LAST_SEEN[$uuid]=$(ka_now_full)
    ka_state_save_target "$uuid"
    ka_log_event "$uuid" TARGET "$reason" UNAVAILABLE
    ka_notify_target_lost "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$reason"
}

# Role: Validate one target against the current discovery snapshot instead of D-Bus.
# Discovery already fetched shellSessionId, processId, and foregroundProcessId for every
# session; periodic health re-fetched exactly the same three properties moments later.
# Reusing the snapshot removes that duplication. Pre-send validation deliberately keeps
# using the live path, because a send must never rely on a snapshot.
ka_state_validate_from_discovery() {
    local uuid=$1 start age max_age
    # Discovery can back off to tens of seconds when nobody is watching, and validating
    # against a snapshot that old would delay noticing a Konsole-side change. Past this
    # age the caller falls back to a live check, which is far cheaper than keeping
    # discovery itself running fast.
    ka_tunable KEEPALIVE_SNAPSHOT_MAX_AGE 10
    max_age=$REPLY
    ka_now_monotonic || return 1
    age=$((REPLY - ${KA_DISCOVERY_STAMP:-0}))
    ((age <= max_age)) || return 1
    # Return 1 only for "no usable snapshot", which is the caller's signal to fall back
    # to a live call. Every field must be present before the snapshot can be trusted.
    [[ -n ${KA_D_TERM_PID[$uuid]+x} && -n ${KA_D_FG_PID[$uuid]+x} ]] || return 1
    [[ ${KA_D_TERM_PID[$uuid]} == "${KA_T_TERM_PID[$uuid]}" ]] || return 11
    [[ -d /proc/${KA_T_AI_PID[$uuid]} ]] || return 12
    start=$(ka_proc_starttime "${KA_T_AI_PID[$uuid]}" 2>/dev/null || true)
    [[ $start == "${KA_T_AI_START[$uuid]}" ]] || return 13
    [[ ${KA_D_FG_PID[$uuid]} =~ ^[0-9]+$ ]] || return 14
    ka_process_is_descendant_of "${KA_D_FG_PID[$uuid]}" "${KA_T_AI_PID[$uuid]}" || return 15
    return 0
}

# Role: Return the consecutive-transient-failure budget before a target is given up on.
ka_state_strike_limit() {
    ka_tunable KEEPALIVE_VALIDATION_STRIKES 5
    printf '%s' "$REPLY"
}

# Role: Validate every non-unavailable monitored target and update last-seen metadata.
# Transient failures are debounced rather than ignored: a bus that never comes back
# still ends in UNAVAILABLE, but a momentary outage or a Konsole restart does not
# destroy every keep-alive on the first failed call.
ka_state_validate_targets() {
    local uuid rc reason limit strikes
    ((${#KA_T_UUIDS[@]} > 0)) || return 0
    limit=$(ka_state_strike_limit)
    for uuid in "${KA_T_UUIDS[@]}"; do
        [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || continue
        # Prefer the snapshot; fall back to a live call only for targets discovery
        # did not see this cycle.
        if ka_state_validate_from_discovery "$uuid"; then
            rc=0
        elif rc=$?; ((rc != 1)); then
            :
        elif ka_konsole_validate_target "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" "$uuid" \
            "${KA_T_TERM_PID[$uuid]}" "${KA_T_AI_PID[$uuid]}" "${KA_T_AI_START[$uuid]}"; then
            rc=0
        else
            rc=$?
        fi
        if ((rc == 0)); then
            KA_T_LAST_SEEN[$uuid]=$(ka_now_full)
            KA_T_STRIKES[$uuid]=0
        else
            reason=$(ka_konsole_validation_reason "$rc")
            if ka_konsole_validation_is_transient "$rc"; then
                strikes=$(( ${KA_T_STRIKES[$uuid]:-0} + 1 ))
                KA_T_STRIKES[$uuid]=$strikes
                ((strikes >= limit)) || continue
                reason="$reason (${strikes} consecutive attempts)"
            fi
            ka_state_mark_unavailable "$uuid" "$reason"
        fi
    done
}

# Role: Publish one atomic merged index containing monitored and currently AVAILABLE sessions.
ka_state_publish_index() {
    local tmp uuid status
    tmp="$KA_RUNTIME_DIR/.index.tmp.$$.$RANDOM"
    : >"$tmp"
    chmod 600 "$tmp" 2>/dev/null || true

    local type name directory last reason
    for uuid in "${KA_T_UUIDS[@]}"; do
        status=${KA_T_STATUS[$uuid]}
        ka_single_line "${KA_T_TYPE[$uuid]}";       type=$REPLY
        ka_single_line "${KA_T_NAME[$uuid]}";       name=$REPLY
        ka_single_line "${KA_T_DIR[$uuid]}";        directory=$REPLY
        ka_single_line "${KA_T_LAST_SEEN[$uuid]-}"; last=$REPLY
        ka_single_line "${KA_T_REASON[$uuid]-}";    reason=$REPLY
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$uuid" "$type" "$name" "$directory" "$status" "${KA_T_MAIN_REMAIN[$uuid]}" \
            "${KA_T_MAIN_INTERVAL[$uuid]}" "${KA_T_SECONDARY_ENABLED[$uuid]}" \
            "${KA_T_SECONDARY_REMAIN[$uuid]}" "${KA_T_SECONDARY_INTERVAL[$uuid]}" \
            "${KA_T_MODE[$uuid]}" "${KA_T_NOTIFY[$uuid]}" "$last" "$reason" >>"$tmp"
    done

    for uuid in "${KA_D_UUIDS[@]}"; do
        ka_state_has_target "$uuid" && continue
        ka_single_line "${KA_D_TYPE[$uuid]}"; type=$REPLY
        ka_single_line "${KA_D_NAME[$uuid]}"; name=$REPLY
        ka_single_line "${KA_D_DIR[$uuid]}";  directory=$REPLY
        printf '%s\t%s\t%s\t%s\tAVAILABLE\t0\t0\t0\t0\t0\t\t0\t\t\n' \
            "$uuid" "$type" "$name" "$directory" >>"$tmp"
    done
    mv -f -- "$tmp" "$KA_INDEX_FILE"
}

# Role: Find one indexed target/available row by UUID for TUI and CLI readers.
ka_state_index_row() {
    local uuid=$1
    [[ -r $KA_INDEX_FILE ]] || return 1
    awk -F '\t' -v id="$uuid" '$1 == id { print; exit }' "$KA_INDEX_FILE"
}

# Role: Read one scalar field from a persisted target state file for client-side rendering.
ka_state_read_field() {
    local uuid=$1 wanted=$2 dir file key value
    ka_state_target_dir "$uuid"; dir=$REPLY
    file="$dir/state.tsv"
    [[ -r $file ]] || return 1
    while IFS=$'\t' read -r key value _; do
        if [[ $key == "$wanted" ]]; then
            printf '%s' "$value"
            return 0
        fi
    done <"$file"
    return 1
}

# Role: Seed a configuration request directory from one existing monitored target.
ka_state_copy_target_to_request() {
    local uuid=$1 request_dir=$2 dir
    ka_state_target_dir "$uuid"; dir=$REPLY
    [[ -r $dir/state.tsv ]] || return 1
    mkdir -p "$request_dir/messages"
    ka_write_scalar "$request_dir/main_interval" "$(ka_state_read_field "$uuid" main_interval)"
    ka_write_scalar "$request_dir/secondary_enabled" "$(ka_state_read_field "$uuid" secondary_enabled)"
    ka_write_scalar "$request_dir/secondary_interval" "$(ka_state_read_field "$uuid" secondary_interval)"
    cp -f -- "$dir/secondary_message" "$request_dir/secondary_message"
    ka_write_scalar "$request_dir/notifications" "$(ka_state_read_field "$uuid" notifications)"
    ka_write_scalar "$request_dir/delivery_mode" "$(ka_state_read_field "$uuid" mode)"
    rm -rf -- "$request_dir/messages"
    mkdir -p "$request_dir/messages"
    cp -f -- "$dir/messages"/[0-9][0-9][0-9] "$request_dir/messages/" 2>/dev/null || true
}
