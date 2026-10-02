#!/usr/bin/env bash
# Authoritative daemon state for monitored targets and current terminal discovery.
# Runtime state is data-only: no target/config file is ever sourced or eval'd.

# Longest last-delivery detail kept: enough to recognize the message in list/detail views.
KA_LAST_DELIVERY_DETAIL_MAX=256

# Role: Initialize all in-memory target and discovery collections used by the daemon.
ka_state_init_arrays() {
    declare -ga KA_T_UUIDS=()
    declare -gA KA_T_BACKEND=() KA_T_TYPE=() KA_T_NAME=() KA_T_DIR=() KA_T_SERVICE=() KA_T_PATH=()
    declare -gA KA_T_TERM_PID=() KA_T_AI_PID=() KA_T_AI_START=() KA_T_STATUS=()
    declare -gA KA_T_ORCA_HANDLE=() KA_T_ORCA_PTY=() KA_T_ORCA_INCARNATION=()
    declare -gA KA_T_ORCA_WORKTREE=() KA_T_ORCA_RUNTIME=() KA_T_ORCA_HOST=()
    declare -gA KA_T_ORCA_TAB=() KA_T_ORCA_LEAF=() KA_T_ORCA_AGENT=()
    declare -gA KA_T_MODE=() KA_T_NOTIFY=() KA_T_MAIN_INTERVAL=() KA_T_MAIN_REMAIN=()
    declare -gA KA_T_MAIN_INDEX=() KA_T_SECONDARY_ENABLED=() KA_T_SECONDARY_INTERVAL=()
    declare -gA KA_T_SECONDARY_REMAIN=() KA_T_SECONDARY_MESSAGE=() KA_T_LAST_SEEN=()
    declare -gA KA_T_LAST_DELIVERY_TIME=() KA_T_LAST_DELIVERY_EVENT=()
    declare -gA KA_T_LAST_DELIVERY_RESULT=() KA_T_LAST_DELIVERY_DETAIL=()
    declare -gA KA_T_REASON=()
    # Consecutive transient validation failures. Runtime-only debounce, never persisted:
    # a checkpoint should not carry a grudge across a daemon restart.
    declare -gA KA_T_STRIKES=()
    # Owner of a message whose text reached the terminal but whose submit did not:
    # 0, MAIN, SECONDARY_AUTO, SECONDARY_MANUAL, or STALE. The scheduler accepts legacy
    # in-memory 1 as MAIN, but checkpoints always write the named enum.
    declare -gA KA_T_PENDING_SUBMIT=()
    # The secondary prompt is a one-shot nudge: once it has fired for this arming it
    # stays quiet until the target is reconfigured.
    declare -gA KA_T_SECONDARY_DONE=()
    # Targets whose in-memory countdown has moved since their last checkpoint. Ticking a
    # countdown does not justify rewriting a whole record every second per target.
    declare -gA KA_T_DIRTY=()

    declare -ga KA_D_UUIDS=()
    declare -gA KA_D_BACKEND=() KA_D_TYPE=() KA_D_NAME=() KA_D_DIR=() KA_D_SERVICE=() KA_D_PATH=()
    declare -gA KA_D_TERM_PID=() KA_D_FG_PID=() KA_D_AI_PID=() KA_D_AI_START=() KA_D_CMD=()
    declare -gA KA_D_ORCA_HANDLE=() KA_D_ORCA_PTY=() KA_D_ORCA_INCARNATION=()
    declare -gA KA_D_ORCA_WORKTREE=() KA_D_ORCA_RUNTIME=() KA_D_ORCA_HOST=()
    declare -gA KA_D_ORCA_TAB=() KA_D_ORCA_LEAF=() KA_D_ORCA_AGENT=()
}

# Role: Put the private runtime directory for one monitored target in REPLY.
ka_state_target_dir() {
    ka_safe_id "$1"
    REPLY="$KA_TARGETS_DIR/$REPLY"
}

# Role: Validate and harden one owned real directory in the private runtime tree.
ka_state_validate_runtime_dir() {
    local path=$1 canonical
    [[ -d $path && ! -L $path && -O $path ]] || return 1
    canonical=$(readlink -f -- "$path") || return 1
    [[ $canonical == "$path" ]] || return 1
    chmod 700 "$path" 2>/dev/null || return 1
}

# Role: Create one previously absent target directory without following a planted link.
ka_state_create_runtime_target_dir() {
    local path=$1
    [[ ! -e $path && ! -L $path ]] || return 1
    mkdir -- "$path" || return 1
    ka_state_validate_runtime_dir "$path" || { rmdir -- "$path" 2>/dev/null || true; return 1; }
}

# Role: Validate a target and its messages destination, allowing the child to be absent.
ka_state_validate_message_destination() {
    local target_dir=$1 messages_dir="$1/messages"
    ka_state_validate_runtime_dir "$target_dir" || return 1
    [[ ! -e $messages_dir && ! -L $messages_dir ]] && return 0
    ka_state_validate_runtime_dir "$messages_dir"
}

# Role: Validate a target and create or harden its owned messages directory.
ka_state_prepare_messages_dir() {
    local target_dir=$1 messages_dir="$1/messages"
    ka_state_validate_runtime_dir "$target_dir" || return 1
    ka_runtime_prepare_dir "$messages_dir"
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

# Role: Canonicalize one pending-submit owner for checkpoint compatibility.
ka_state_pending_submit_value() {
    local uuid=$1
    local pending=${KA_T_PENDING_SUBMIT[$uuid]:-0}
    case $pending in
        0|MAIN|SECONDARY_AUTO|SECONDARY_MANUAL|STALE) REPLY=$pending ;;
        1) REPLY=MAIN ;;
        *) REPLY=STALE ;;
    esac
}

# Role: Checkpoint every target whose countdown has moved since the last flush.
#
# Countdown decrements used to be checkpointed on every tick, which rewrote a full record
# per target per second purely to persist a decremented number. Recovery already treats
# daemon downtime as a preserved gap, so a periodic flush loses nothing that matters:
# the worst case is a countdown that resumes at most one flush interval stale.
ka_state_flush_dirty() {
    local uuid failed=0
    for uuid in "${!KA_T_DIRTY[@]}"; do
        ka_state_has_target "$uuid" || { unset 'KA_T_DIRTY[$uuid]'; continue; }
        ka_state_save_target "$uuid" || failed=1
    done
    return "$failed"
}

# Role: Append one sanitized key/value row to the checkpoint payload being built.
# Kept as a helper so every field is written the same way and nothing forks per field.
ka_state_payload_row() {
    ka_single_line "$2"
    KA_STATE_PAYLOAD+="$1"$'\t'"$REPLY"$'\n'
}

# Role: Put the versioned secondary companion a target checkpoint references in REPLY.
# REPLY is empty for a legacy checkpoint or one without a valid modern reference. Fails
# only when an existing state.tsv is not an owned, readable regular file.
ka_state_referenced_companion() {
    local file="$1/state.tsv" key value extra
    REPLY=''
    [[ -e $file || -L $file ]] || return 0
    [[ -f $file && ! -L $file && -O $file && -r $file ]] || return 1
    while IFS=$'\t' read -r key value extra; do
        if [[ $key == secondary_message_file && -z $extra \
            && $value =~ ^secondary_message\.[0-9]+\.[0-9]+$ ]]; then
            REPLY=$value
            break
        fi
    done <"$file"
    return 0
}

# Role: Delete versioned secondary companions that a loaded checkpoint does not reference.
# A crash between committing state.tsv and removing the previous companion leaves one
# orphan per occurrence, and nothing else ever collects them. Daemon startup only.
ka_state_prune_secondary_companions() {
    local dir=$1 keep path had_nullglob=0
    # Only ever one target directory: a direct child of the targets root, never the root
    # itself or anything nested deeper. The globbed directory must also be a real owned
    # directory, or a symlinked target (or targets root) would steer the deletion outside
    # the runtime tree.
    [[ $dir == "$KA_TARGETS_DIR"/* && ${dir#"$KA_TARGETS_DIR"/} != */* ]] || return 0
    ka_state_validate_runtime_dir "$KA_TARGETS_DIR" || return 0
    ka_state_validate_runtime_dir "$dir" || return 0
    ka_state_referenced_companion "$dir" || return 0
    keep=$REPLY
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
    for path in "$dir"/secondary_message.*; do
        [[ ${path##*/} =~ ^secondary_message\.[0-9]+\.[0-9]+$ && ${path##*/} != "$keep" ]] || continue
        [[ -f $path && ! -L $path && -O $path ]] || continue
        rm -f -- "$path" 2>/dev/null || true
    done
    ((had_nullglob == 1)) || shopt -u nullglob
    return 0
}

# Role: Remove temporary files abandoned by an interrupted daemon write. Daemon startup only.
# Atomic writers and log trimming leave `.<name>.tmp.*` and `<log>.trim.*` files behind only
# when the process dies between creating and renaming them, and nothing collected those.
# Only directories the daemon alone writes are swept; request directories belong to clients
# that may be writing them right now, and have their own age-based cleanup.
ka_state_sweep_temp_files() {
    local path had_nullglob=0 had_dotglob=0
    local -a candidates=()
    shopt -q nullglob && had_nullglob=1
    shopt -q dotglob && had_dotglob=1
    shopt -s nullglob dotglob
    # Each root is re-validated as an owned, canonical, non-symlink directory first: a
    # replaced root would otherwise make every glob below it resolve somewhere else.
    if ka_state_validate_runtime_dir "$KA_RUNTIME_DIR"; then
        candidates+=("$KA_RUNTIME_DIR"/.*.tmp.*)
        ka_state_validate_runtime_dir "$KA_TARGETS_DIR" && candidates+=("$KA_TARGETS_DIR"/*/.*.tmp.*)
        ka_state_validate_runtime_dir "$KA_LOGS_DIR" && candidates+=("$KA_LOGS_DIR"/*.trim.*)
    fi
    for path in "${candidates[@]}"; do
        # A symlinked target entry must not steer the sweep outside the runtime tree.
        [[ -d ${path%/*} && ! -L ${path%/*} ]] || continue
        [[ -f $path && ! -L $path && -O $path ]] || continue
        rm -f -- "$path" 2>/dev/null || true
    done
    ((had_nullglob == 1)) || shopt -u nullglob
    ((had_dotglob == 1)) || shopt -u dotglob
    return 0
}

# Role: Save one monitored target's mutable scalar state using atomic file replacement.
ka_state_save_target() {
    local uuid=$1 dir file old_secondary_file=''
    local secondary_file secondary_path pending_submit
    ka_state_target_dir "$uuid"; dir=$REPLY
    ka_state_prepare_messages_dir "$dir" || return 1
    file="$dir/state.tsv"
    ka_state_referenced_companion "$dir" || return 1
    old_secondary_file=$REPLY
    ka_state_pending_submit_value "$uuid"
    pending_submit=$REPLY
    # Every save commits a fresh companion. Reusing an unchanged one saved a single rename
    # per flush, but deciding "unchanged" meant reading a file that could be swapped between
    # that check and the state commit, leaving state.tsv naming something it never verified.
    while :; do
        secondary_file="secondary_message.$$.$RANDOM"
        secondary_path="$dir/$secondary_file"
        [[ ! -e $secondary_path && ! -L $secondary_path ]] && break
    done
    ka_atomic_write_value "$secondary_path" "${KA_T_SECONDARY_MESSAGE[$uuid]-}" || return 1
    KA_STATE_PAYLOAD=''
    ka_state_payload_row uuid                "$uuid"
    ka_state_payload_row backend             "${KA_T_BACKEND[$uuid]:-konsole}"
    ka_state_payload_row type                "${KA_T_TYPE[$uuid]}"
    ka_state_payload_row name                "${KA_T_NAME[$uuid]}"
    ka_state_payload_row directory           "${KA_T_DIR[$uuid]}"
    ka_state_payload_row service             "${KA_T_SERVICE[$uuid]-}"
    ka_state_payload_row path                "${KA_T_PATH[$uuid]-}"
    ka_state_payload_row term_pid            "${KA_T_TERM_PID[$uuid]-}"
    ka_state_payload_row ai_pid              "${KA_T_AI_PID[$uuid]-}"
    ka_state_payload_row ai_start            "${KA_T_AI_START[$uuid]-}"
    ka_state_payload_row orca_handle         "${KA_T_ORCA_HANDLE[$uuid]-}"
    ka_state_payload_row orca_pty             "${KA_T_ORCA_PTY[$uuid]-}"
    ka_state_payload_row orca_incarnation     "${KA_T_ORCA_INCARNATION[$uuid]-}"
    ka_state_payload_row orca_worktree        "${KA_T_ORCA_WORKTREE[$uuid]-}"
    ka_state_payload_row orca_runtime         "${KA_T_ORCA_RUNTIME[$uuid]-}"
    ka_state_payload_row orca_host            "${KA_T_ORCA_HOST[$uuid]-}"
    ka_state_payload_row orca_tab             "${KA_T_ORCA_TAB[$uuid]-}"
    ka_state_payload_row orca_leaf            "${KA_T_ORCA_LEAF[$uuid]-}"
    ka_state_payload_row orca_agent           "${KA_T_ORCA_AGENT[$uuid]-}"
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
    ka_state_payload_row secondary_message_file "$secondary_file"
    ka_state_payload_row last_seen           "${KA_T_LAST_SEEN[$uuid]-}"
    ka_state_payload_row reason              "${KA_T_REASON[$uuid]-}"
    ka_state_payload_row pending_submit     "$pending_submit"
    # These fields are deliberately appended: older daemons ignore unknown checkpoint
    # keys, while a new daemon treats their absence as the never-delivered state.
    ka_state_payload_row last_delivery_time   "${KA_T_LAST_DELIVERY_TIME[$uuid]-}"
    ka_state_payload_row last_delivery_event  "${KA_T_LAST_DELIVERY_EVENT[$uuid]-}"
    ka_state_payload_row last_delivery_result "${KA_T_LAST_DELIVERY_RESULT[$uuid]-}"
    ka_state_payload_row last_delivery_detail "${KA_T_LAST_DELIVERY_DETAIL[$uuid]-}"
    if ! ka_atomic_write_value "$file" "$KA_STATE_PAYLOAD"; then
        rm -f -- "$secondary_path"
        return 1
    fi
    if [[ -n $old_secondary_file && $old_secondary_file != "$secondary_file" ]]; then
        rm -f -- "$dir/$old_secondary_file" 2>/dev/null || true
    fi
    # Tested first: a builtin check is free, while rm would fork on every save.
    if [[ -e $dir/secondary_message || -L $dir/secondary_message ]]; then
        rm -f -- "$dir/secondary_message" 2>/dev/null || true
    fi
    unset 'KA_T_DIRTY[$uuid]'
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
    ka_state_validate_runtime_dir "$dir" \
        || { ka_state_load_reject 'target entry is not an owned real directory'; return 1; }
    ka_state_validate_runtime_dir "$dir/messages" \
        || { ka_state_load_reject 'messages path is not an owned real directory'; return 1; }
    [[ -f $file && ! -L $file && -O $file ]] \
        || { ka_state_load_reject 'state.tsv is missing or not an owned regular file'; return 1; }
    local key value extra uuid='' backend='konsole'
    local type='' name='' directory='' service='' path='' term_pid='' ai_pid='' ai_start=''
    local orca_handle='' orca_pty='' orca_incarnation='' orca_worktree='' orca_runtime=''
    local orca_host='' orca_tab='' orca_leaf='' orca_agent=''
    local status='' mode='' notifications='' main_interval='' main_remaining='' main_index=''
    local secondary_enabled='' secondary_interval='' secondary_remaining='' last_seen='' reason=''
    local secondary_done='' secondary_message_file='' pending_submit=''
    local last_delivery_time='' last_delivery_event='' last_delivery_result='' last_delivery_detail=''
    local parse_error='' secondary_message='' secondary_path='' message_count=0 safe_uuid=''
    local -A seen=()
    local delivery_malformed=0

    while IFS=$'\t' read -r key value extra; do
        # Display-only delivery metadata is never a reason to reject the target: a
        # duplicated or split field just clears all four (see below).
        if [[ $key == last_delivery_* ]] && [[ -n ${seen[$key]+x} || -n $extra ]]; then
            delivery_malformed=1
            continue
        fi
        case $key in
            uuid|backend|type|name|directory|service|path|term_pid|ai_pid|ai_start|orca_handle|orca_pty|orca_incarnation|orca_worktree|orca_runtime|orca_host|orca_tab|orca_leaf|orca_agent|status|mode|notifications|main_interval|main_remaining|main_index|secondary_enabled|secondary_interval|secondary_remaining|secondary_done|secondary_message_file|last_seen|reason|pending_submit|last_delivery_time|last_delivery_event|last_delivery_result|last_delivery_detail)
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
            backend) backend=$value ;;
            type) type=$value ;;
            name) name=$value ;;
            directory) directory=$value ;;
            service) service=$value ;;
            path) path=$value ;;
            term_pid) term_pid=$value ;;
            ai_pid) ai_pid=$value ;;
            ai_start) ai_start=$value ;;
            orca_handle) orca_handle=$value ;;
            orca_pty) orca_pty=$value ;;
            orca_incarnation) orca_incarnation=$value ;;
            orca_worktree) orca_worktree=$value ;;
            orca_runtime) orca_runtime=$value ;;
            orca_host) orca_host=$value ;;
            orca_tab) orca_tab=$value ;;
            orca_leaf) orca_leaf=$value ;;
            orca_agent) orca_agent=$value ;;
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
            secondary_message_file) secondary_message_file=$value ;;
            last_seen) last_seen=$value ;;
            reason) reason=$value ;;
            pending_submit) pending_submit=$value ;;
            last_delivery_time) last_delivery_time=$value ;;
            last_delivery_event) last_delivery_event=$value ;;
            last_delivery_result) last_delivery_result=$value ;;
            last_delivery_detail) last_delivery_detail=$value ;;
        esac
    done <"$file"

    [[ -z $parse_error ]] || { ka_state_load_reject "$parse_error"; return 1; }
    local required
    for required in uuid type name directory status mode notifications \
        main_interval main_remaining main_index secondary_enabled secondary_interval secondary_remaining last_seen reason; do
        [[ -n ${seen[$required]+x} ]] || { ka_state_load_reject "missing state field: $required"; return 1; }
    done

    [[ -n $uuid && ${#uuid} -le 256 ]] || { ka_state_load_reject 'uuid is empty or unreasonably long'; return 1; }
    ka_safe_id "$uuid"; safe_uuid=$REPLY
    [[ ${dir##*/} == "$safe_uuid" ]] || { ka_state_load_reject 'target directory does not match stored uuid'; return 1; }
    [[ -n $type && -n $name && -n $directory ]] || { ka_state_load_reject 'type, name, and directory are required'; return 1; }
    case $backend in
        konsole)
            for required in service path term_pid ai_pid ai_start; do
                [[ -n ${seen[$required]+x} ]] || {
                    ka_state_load_reject "missing Konsole state field: $required"
                    return 1
                }
            done
            [[ $service =~ ^org\.kde\.konsole(-[0-9]+)?$ ]] || { ka_state_load_reject 'invalid Konsole D-Bus service'; return 1; }
            [[ $path =~ ^/Sessions/[0-9]+$ ]] || { ka_state_load_reject 'invalid Konsole session path'; return 1; }
            ka_is_positive_int "$term_pid" || { ka_state_load_reject 'term_pid must be positive'; return 1; }
            ka_is_positive_int "$ai_pid" || { ka_state_load_reject 'ai_pid must be positive'; return 1; }
            ka_is_positive_int "$ai_start" || { ka_state_load_reject 'ai_start must be positive'; return 1; }
            ;;
        orca)
            for required in orca_handle orca_pty orca_incarnation orca_worktree orca_runtime \
                orca_host orca_tab orca_leaf orca_agent; do
                [[ -n ${seen[$required]+x} ]] || {
                    ka_state_load_reject "missing Orca state field: $required"
                    return 1
                }
            done
            if ! ka_orca_checkpoint_binding_valid "$uuid" "$orca_handle" "$orca_pty" \
                "$orca_incarnation" "$orca_worktree" "$orca_runtime" "$orca_host" \
                "$orca_tab" "$orca_leaf" "$orca_agent"; then
                ka_state_load_reject "$KA_ORCA_BINDING_ERROR"
                return 1
            fi
            ;;
        *)
            ka_state_load_reject "unsupported terminal backend: $backend"
            return 1
            ;;
    esac
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
    # Absence is valid for legacy checkpoints; an explicitly empty modern field is not.
    if [[ -n ${seen[secondary_done]+x} ]]; then
        [[ $secondary_done == 0 || $secondary_done == 1 ]] || {
            ka_state_load_reject 'secondary_done must be 0 or 1'
            return 1
        }
    else
        secondary_done=0
    fi
    if [[ -n ${seen[pending_submit]+x} ]]; then
        case $pending_submit in
            0|MAIN|SECONDARY_AUTO|SECONDARY_MANUAL|STALE) ;;
            # The pre-enum flag value; ka_state_pending_submit_value maps it the same way.
            1) pending_submit=MAIN ;;
            *)
                ka_state_load_reject 'pending_submit must be 0, MAIN, SECONDARY_AUTO, SECONDARY_MANUAL, or STALE'
                return 1
                ;;
        esac
    else
        pending_submit=0
    fi
    # The last-delivery fields are display metadata only. A value outside its shape is
    # dropped or shortened rather than rejected: quarantining a healthy target over a
    # cosmetic field (or a detail longer than a since-lowered message limit) would cost
    # the user the target itself.
    ((delivery_malformed == 0)) || last_delivery_event=''
    case $last_delivery_event in
        MAIN|SECONDARY|ENTER) ;;
        *) last_delivery_event='' last_delivery_time='' last_delivery_result='' last_delivery_detail='' ;;
    esac
    last_delivery_time=${last_delivery_time:0:64}
    last_delivery_result=${last_delivery_result:0:128}
    last_delivery_detail=${last_delivery_detail:0:${KA_LAST_DELIVERY_DETAIL_MAX:-256}}
    if [[ -n ${seen[secondary_message_file]+x} ]]; then
        [[ $secondary_message_file =~ ^secondary_message\.[0-9]+\.[0-9]+$ ]] || {
            ka_state_load_reject 'secondary message checkpoint reference is invalid'
            return 1
        }
        secondary_path="$dir/$secondary_message_file"
    else
        # Checkpoints from earlier releases used one fixed companion file.
        secondary_path="$dir/secondary_message"
    fi
    [[ -f $secondary_path && ! -L $secondary_path && -O $secondary_path ]] || {
        ka_state_load_reject 'secondary_message is missing or not an owned regular file'
        return 1
    }
    # Bounded like every other message read: an oversized companion must not be pulled
    # into daemon memory. A disabled secondary was never validated and is never sent, so
    # an unreadable one only loses its stale text instead of quarantining the target.
    local max_len
    ka_tunable KEEPALIVE_MAX_MESSAGE_LENGTH 2000
    max_len=$REPLY
    if ka_request_read_scalar "$secondary_path" "$max_len"; then
        secondary_message=$REPLY
    elif [[ $secondary_enabled == 1 ]]; then
        ka_state_load_reject "enabled secondary_message must be one logical line of at most $max_len characters"
        return 1
    else
        secondary_message=''
    fi
    if [[ $secondary_enabled == 1 && -z $secondary_message ]]; then
        ka_state_load_reject 'enabled secondary_message must be one non-empty logical line'
        return 1
    fi
    ka_profile_validate_main_messages "$dir/messages" >/dev/null 2>&1 || {
        ka_state_load_reject 'main message rotation is not contiguous non-empty 001..N'
        return 1
    }
    message_count=$(ka_state_message_count "$uuid") || {
        ka_state_load_reject 'main message rotation contains an unsafe path'
        return 1
    }
    ((main_index < message_count)) || { ka_state_load_reject 'main_index exceeds message rotation'; return 1; }

    ka_state_register_uuid "$uuid"
    KA_T_BACKEND[$uuid]=$backend
    KA_T_TYPE[$uuid]=$type
    KA_T_NAME[$uuid]=$name
    KA_T_DIR[$uuid]=$directory
    KA_T_SERVICE[$uuid]=$service
    KA_T_PATH[$uuid]=$path
    KA_T_TERM_PID[$uuid]=$term_pid
    KA_T_AI_PID[$uuid]=$ai_pid
    KA_T_AI_START[$uuid]=$ai_start
    KA_T_ORCA_HANDLE[$uuid]=$orca_handle
    KA_T_ORCA_PTY[$uuid]=$orca_pty
    KA_T_ORCA_INCARNATION[$uuid]=$orca_incarnation
    KA_T_ORCA_WORKTREE[$uuid]=$orca_worktree
    KA_T_ORCA_RUNTIME[$uuid]=$orca_runtime
    KA_T_ORCA_HOST[$uuid]=$orca_host
    KA_T_ORCA_TAB[$uuid]=$orca_tab
    KA_T_ORCA_LEAF[$uuid]=$orca_leaf
    KA_T_ORCA_AGENT[$uuid]=$orca_agent
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
    KA_T_LAST_DELIVERY_TIME[$uuid]=$last_delivery_time
    KA_T_LAST_DELIVERY_EVENT[$uuid]=$last_delivery_event
    KA_T_LAST_DELIVERY_RESULT[$uuid]=$last_delivery_result
    KA_T_LAST_DELIVERY_DETAIL[$uuid]=$last_delivery_detail
    KA_T_STRIKES[$uuid]=0
    KA_T_PENDING_SUBMIT[$uuid]=$pending_submit
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

# Role: Recover interrupted target-message commits before stale rollback trees are swept.
ka_state_recover_target_messages() {
    local dir recovery_failed=0 had_nullglob=0 had_dotglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -q dotglob && had_dotglob=1
    shopt -s nullglob dotglob
    for dir in "$KA_TARGETS_DIR"/*; do
        [[ -d $dir && ! -L $dir && -O $dir ]] || continue
        if ! ka_state_validate_runtime_dir "$dir"; then
            continue
        fi
        if ! ka_recover_staged_dir "$dir/messages"; then
            if ! ka_state_quarantine_target_dir "$dir" \
                'interrupted message commit could not be recovered safely'; then
                recovery_failed=1
            fi
        fi
    done
    ((had_nullglob == 1)) || shopt -u nullglob
    ((had_dotglob == 1)) || shopt -u dotglob
    return "$recovery_failed"
}

# Role: Restore valid runtime targets and quarantine malformed records with reasons.
ka_state_load_all_targets() {
    local dir reason quarantine_failed=0 had_nullglob=0 had_dotglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -q dotglob && had_dotglob=1
    shopt -s nullglob dotglob
    for dir in "$KA_TARGETS_DIR"/*; do
        if [[ ! -d $dir || -L $dir ]]; then
            ka_state_quarantine_target_dir "$dir" 'target entry is not a regular directory' \
                || quarantine_failed=1
            continue
        fi
        if ka_state_load_target_dir "$dir"; then
            ka_state_prune_secondary_companions "$dir"
        else
            reason=${KA_STATE_LOAD_ERROR:-'unknown checkpoint validation failure'}
            ka_state_quarantine_target_dir "$dir" "$reason" || quarantine_failed=1
        fi
    done
    ((had_nullglob == 1)) || shopt -u nullglob
    ((had_dotglob == 1)) || shopt -u dotglob
    return "$quarantine_failed"
}

# Role: Remove one backend's rows while preserving the other backend snapshots.
ka_state_clear_discovery_backend() {
    local backend=$1 uuid
    local -a keep=()
    for uuid in "${KA_D_UUIDS[@]}"; do
        if [[ ${KA_D_BACKEND[$uuid]:-konsole} != "$backend" ]]; then
            keep+=("$uuid")
            continue
        fi
        unset 'KA_D_BACKEND[$uuid]' 'KA_D_TYPE[$uuid]' 'KA_D_NAME[$uuid]' 'KA_D_DIR[$uuid]'
        unset 'KA_D_SERVICE[$uuid]' 'KA_D_PATH[$uuid]' 'KA_D_TERM_PID[$uuid]' 'KA_D_FG_PID[$uuid]'
        unset 'KA_D_AI_PID[$uuid]' 'KA_D_AI_START[$uuid]' 'KA_D_CMD[$uuid]'
        unset 'KA_D_ORCA_HANDLE[$uuid]' 'KA_D_ORCA_PTY[$uuid]' 'KA_D_ORCA_INCARNATION[$uuid]'
        unset 'KA_D_ORCA_WORKTREE[$uuid]' 'KA_D_ORCA_RUNTIME[$uuid]' 'KA_D_ORCA_HOST[$uuid]'
        unset 'KA_D_ORCA_TAB[$uuid]' 'KA_D_ORCA_LEAF[$uuid]' 'KA_D_ORCA_AGENT[$uuid]'
    done
    KA_D_UUIDS=("${keep[@]}")
}

# Role: Replace only the Konsole discovery snapshot after one complete bounded pass.
ka_state_refresh_konsole_discovery() {
    local -a n_uuids=()
    local -A n_type=() n_name=() n_dir=() n_service=() n_path=()
    local -A n_term=() n_fg=() n_ai=() n_start=() n_cmd=()
    local complete=0 uuid type name directory service path term_pid fgpid ai_pid ai_start cmd key row

    # Called directly, not through a process substitution: discovery then runs in this
    # shell, where the classifier's executable cache persists between passes.
    ka_konsole_discover_rows
    for row in "${KA_DISCOVERY_ROWS[@]}"; do
        IFS=$'\t' read -r uuid type name directory service path term_pid fgpid ai_pid ai_start cmd <<<"$row"
        case $uuid in
            '#COMPLETE') complete=1; continue ;;
            '#INCOMPLETE') complete=0; continue ;;
            '') continue ;;
        esac
        [[ -n ${n_type[$uuid]+x} ]] || n_uuids+=("$uuid")
        n_type[$uuid]=$type; n_name[$uuid]=$name; n_dir[$uuid]=$directory
        n_service[$uuid]=$service; n_path[$uuid]=$path; n_term[$uuid]=$term_pid
        n_fg[$uuid]=$fgpid; n_ai[$uuid]=$ai_pid; n_start[$uuid]=$ai_start; n_cmd[$uuid]=$cmd
    done

    # A truncated pass would look like sessions disappearing, so keep the previous
    # snapshot and let the caller decide whether to warn.
    if ((complete != 1)); then
        return 1
    fi
    ka_now_monotonic && {
        KA_DISCOVERY_STAMP_KONSOLE=$REPLY
        # Compatibility alias used by older tests and external diagnostics.
        KA_DISCOVERY_STAMP=$REPLY
    }
    ka_state_clear_discovery_backend konsole
    for key in "${n_uuids[@]}"; do
        KA_D_UUIDS+=("$key")
        KA_D_BACKEND[$key]=konsole
        KA_D_TYPE[$key]=${n_type[$key]}; KA_D_NAME[$key]=${n_name[$key]}; KA_D_DIR[$key]=${n_dir[$key]}
        KA_D_SERVICE[$key]=${n_service[$key]}; KA_D_PATH[$key]=${n_path[$key]}
        KA_D_TERM_PID[$key]=${n_term[$key]}; KA_D_FG_PID[$key]=${n_fg[$key]}
        KA_D_AI_PID[$key]=${n_ai[$key]}; KA_D_AI_START[$key]=${n_start[$key]}; KA_D_CMD[$key]=${n_cmd[$key]}
    done
    return 0
}

# Role: Replace only the Orca discovery snapshot after one complete normalized CLI response.
ka_state_refresh_orca_discovery() {
    local -a n_uuids=()
    local -A n_agent=() n_name=() n_dir=() n_handle=() n_pty=() n_incarnation=()
    local -A n_worktree=() n_runtime=() n_host=() n_tab=() n_leaf=()
    local complete=0 uuid agent name directory handle pty incarnation worktree runtime host tab leaf key
    local incomplete_reason='no-marker'

    while IFS=$'\t' read -r uuid agent name directory handle pty incarnation worktree runtime host tab leaf; do
        case $uuid in
            '#COMPLETE') complete=1; continue ;;
            '#INCOMPLETE') complete=0; incomplete_reason=${agent:-unknown}; continue ;;
            '') continue ;;
        esac
        [[ -n ${n_agent[$uuid]+x} ]] || n_uuids+=("$uuid")
        n_agent[$uuid]=$agent; n_name[$uuid]=$name; n_dir[$uuid]=$directory
        n_handle[$uuid]=$handle; n_pty[$uuid]=$pty; n_incarnation[$uuid]=$incarnation
        n_worktree[$uuid]=$worktree; n_runtime[$uuid]=$runtime; n_host[$uuid]=$host
        n_tab[$uuid]=$tab; n_leaf[$uuid]=$leaf
    done < <(ka_orca_discover)

    # Recorded for the service loop, which backs off an unreachable Orca runtime. The
    # adapter runs in a process substitution, so it cannot keep that state itself.
    if ((complete != 1)); then
        KA_ORCA_DISCOVERY_FAILURE=$incomplete_reason
        return 1
    fi
    KA_ORCA_DISCOVERY_FAILURE=''
    ka_now_monotonic && KA_DISCOVERY_STAMP_ORCA=$REPLY
    ka_state_clear_discovery_backend orca
    for key in "${n_uuids[@]}"; do
        KA_D_UUIDS+=("$key")
        KA_D_BACKEND[$key]=orca
        ka_orca_agent_label "${n_agent[$key]}"
        KA_D_TYPE[$key]=$REPLY
        KA_D_NAME[$key]=${n_name[$key]}
        KA_D_DIR[$key]=${n_dir[$key]}
        KA_D_ORCA_HANDLE[$key]=${n_handle[$key]}
        KA_D_ORCA_PTY[$key]=${n_pty[$key]}
        KA_D_ORCA_INCARNATION[$key]=${n_incarnation[$key]}
        KA_D_ORCA_WORKTREE[$key]=${n_worktree[$key]}
        KA_D_ORCA_RUNTIME[$key]=${n_runtime[$key]}
        KA_D_ORCA_HOST[$key]=${n_host[$key]}
        KA_D_ORCA_TAB[$key]=${n_tab[$key]}
        KA_D_ORCA_LEAF[$key]=${n_leaf[$key]}
        KA_D_ORCA_AGENT[$key]=${n_agent[$key]}
        KA_D_CMD[$key]=${n_name[$key]}
    done
    return 0
}

# Role: Refresh every enabled backend independently so one evolving provider cannot erase another.
# Optional arguments (`konsole`, `orca`) restrict the pass to those backends; with none,
# every enabled backend is refreshed. Snapshots of backends left out are kept as they are.
ka_state_refresh_discovery() {
    local failed=0 want_konsole=1 want_orca=1 backend
    local -a stale=()
    if (($# > 0)); then
        want_konsole=0
        want_orca=0
        for backend in "$@"; do
            case $backend in
                konsole) want_konsole=1 ;;
                orca) want_orca=1 ;;
            esac
        done
    fi
    if ((want_konsole == 1)) && [[ ${KA_KONSOLE_ENABLED:-1} == 1 ]]; then
        if ! ka_state_refresh_konsole_discovery; then
            failed=1
            stale+=(Konsole)
        fi
    fi
    if ((want_orca == 1)) && [[ ${KA_ORCA_ENABLED:-0} == 1 ]]; then
        if ! ka_state_refresh_orca_discovery; then
            failed=1
            stale+=(Orca)
        fi
    fi
    KA_DISCOVERY_STALE=$failed
    KA_DISCOVERY_STALE_BACKENDS=${stale[*]-}
    ((failed == 0))
}

# Role: Copy a validated wizard request's message rotation into a target runtime directory.
ka_state_copy_request_messages() {
    local request_dir=$1 target_dir=$2 staged file name max_len
    ka_state_validate_message_destination "$target_dir" || return 1
    ka_request_validate_dir "$request_dir" || return 1
    ka_request_validate_dir "$request_dir/messages" || return 1
    ka_tunable KEEPALIVE_MAX_MESSAGE_LENGTH 2000
    max_len=$REPLY
    staged=$(mktemp -d "$target_dir/messages.staged.XXXXXX") || return 1
    chmod 700 "$staged" 2>/dev/null || { rm -rf -- "$staged"; return 1; }
    shopt -s nullglob
    local -a files=("$request_dir/messages"/[0-9][0-9][0-9])
    shopt -u nullglob
    ((${#files[@]} > 0)) || { rm -rf -- "$staged"; return 1; }
    for file in "${files[@]}"; do
        name=${file##*/}
        ka_request_copy_file "$file" "$staged/$name" "$max_len" \
            || { rm -rf -- "$staged"; return 1; }
    done
    chmod 600 "$staged"/* 2>/dev/null || { rm -rf -- "$staged"; return 1; }
    ka_commit_staged_dir "$staged" "$target_dir/messages"
}

# Role: Apply one validated request to a target and durably checkpoint the new settings.
ka_state_apply_request_configuration() {
    local uuid=$1 request_dir=$2 target_dir secondary_message pending_submit
    local mode notifications main_interval secondary_enabled secondary_interval max_len
    ka_state_target_dir "$uuid"; target_dir=$REPLY
    ka_request_read_scalar "$request_dir/delivery_mode" 64 || return 1
    mode=$REPLY
    ka_request_read_scalar "$request_dir/notifications" 64 || return 1
    notifications=$REPLY
    ka_request_read_scalar "$request_dir/main_interval" 64 || return 1
    main_interval=$REPLY
    ka_request_read_scalar "$request_dir/secondary_enabled" 64 || return 1
    secondary_enabled=$REPLY
    ka_request_read_scalar "$request_dir/secondary_interval" 64 || return 1
    secondary_interval=$REPLY
    ka_tunable KEEPALIVE_MAX_MESSAGE_LENGTH 2000
    max_len=$REPLY
    ka_request_read_scalar "$request_dir/secondary_message" "$max_len" || return 1
    secondary_message=$REPLY

    ka_state_pending_submit_value "$uuid"
    pending_submit=$REPLY
    [[ $pending_submit == 0 ]] && pending_submit=0 || pending_submit=STALE
    KA_T_PENDING_SUBMIT[$uuid]=$pending_submit
    KA_T_MODE[$uuid]=$mode
    KA_T_NOTIFY[$uuid]=$notifications
    KA_T_MAIN_INTERVAL[$uuid]=$main_interval
    KA_T_MAIN_REMAIN[$uuid]=$main_interval
    KA_T_MAIN_INDEX[$uuid]=0
    KA_T_SECONDARY_ENABLED[$uuid]=$secondary_enabled
    KA_T_SECONDARY_INTERVAL[$uuid]=$secondary_interval
    KA_T_SECONDARY_REMAIN[$uuid]=$secondary_interval
    KA_T_SECONDARY_DONE[$uuid]=0
    KA_T_SECONDARY_MESSAGE[$uuid]=$secondary_message
    # Commit the checkpoint (index 0, any owed submit STALE) before swapping messages/.
    # A daemon killed between the two then restarts with a valid pair - index 0 exists in
    # every rotation and a STALE Enter never advances it - instead of the old index and
    # owner applied to the new rotation, which skips a line or quarantines the target.
    # The restore path keeps the opposite order for the same reason.
    ka_state_save_target "$uuid" || return 1
    ka_state_copy_request_messages "$request_dir" "$target_dir"
}

# Role: Restore an exact pre-configuration target snapshot after a failed commit.
ka_state_restore_configuration() {
    local uuid=$1 request_dir=$2 mode=$3 notifications=$4 main_interval=$5
    local main_remaining=$6 main_index=$7 secondary_enabled=$8 secondary_interval=$9
    shift 9
    local secondary_remaining=$1 secondary_done=$2 secondary_message=$3 target_dir pending_submit
    ka_state_target_dir "$uuid"; target_dir=$REPLY
    ka_state_copy_request_messages "$request_dir" "$target_dir" || return 1
    ka_state_pending_submit_value "$uuid"
    pending_submit=$REPLY
    [[ $pending_submit == 0 ]] && pending_submit=0 || pending_submit=STALE
    KA_T_PENDING_SUBMIT[$uuid]=$pending_submit
    KA_T_MODE[$uuid]=$mode
    KA_T_NOTIFY[$uuid]=$notifications
    KA_T_MAIN_INTERVAL[$uuid]=$main_interval
    KA_T_MAIN_REMAIN[$uuid]=$main_remaining
    KA_T_MAIN_INDEX[$uuid]=$main_index
    KA_T_SECONDARY_ENABLED[$uuid]=$secondary_enabled
    KA_T_SECONDARY_INTERVAL[$uuid]=$secondary_interval
    KA_T_SECONDARY_REMAIN[$uuid]=$secondary_remaining
    KA_T_SECONDARY_DONE[$uuid]=$secondary_done
    KA_T_SECONDARY_MESSAGE[$uuid]=$secondary_message
    ka_state_save_target "$uuid"
}

# Role: Count non-empty stored main messages for one monitored target.
ka_state_message_count() {
    local uuid=$1 dir file count=0
    ka_state_target_dir "$uuid"; dir=$REPLY
    ka_state_validate_runtime_dir "$dir" || return 1
    ka_state_validate_runtime_dir "$dir/messages" || return 1
    shopt -s nullglob
    for file in "$dir/messages"/[0-9][0-9][0-9]; do
        [[ -f $file && ! -L $file && -O $file && -s $file ]] \
            || { shopt -u nullglob; return 1; }
        ((count += 1))
    done
    shopt -u nullglob
    printf '%d' "$count"
}

# Role: Return one zero-based message by rotation index for a monitored target.
ka_state_message_at() {
    local uuid=$1 index=$2 dir file number
    ka_state_target_dir "$uuid"; dir=$REPLY
    ka_state_validate_runtime_dir "$dir" || return 1
    ka_state_validate_runtime_dir "$dir/messages" || return 1
    number=$((index + 1))
    printf -v file '%s/messages/%03d' "$dir" "$number"
    [[ -f $file && ! -L $file && -O $file && -r $file ]] || return 1
    cat -- "$file"
}

# Role: Create a new ACTIVE keep-alive from a currently AVAILABLE discovered session.
ka_state_create_target() {
    local uuid=$1 request_dir=$2
    ka_state_has_target "$uuid" && { ka_error 'target already has a keep-alive'; return 1; }
    [[ -n ${KA_D_TYPE[$uuid]+x} ]] || { ka_error 'selected terminal session is no longer available'; return 1; }
    ka_profile_validate_request "$request_dir" || return 1

    local target_dir main_interval secondary_interval max_len
    ka_state_target_dir "$uuid"; target_dir=$REPLY
    ka_state_create_runtime_target_dir "$target_dir" \
        || { ka_error 'could not create target runtime state'; return 1; }
    local copy_rc=0
    ka_state_copy_request_messages "$request_dir" "$target_dir" || copy_rc=$?
    if ((copy_rc != 0)); then
        if ((copy_rc != 2)) && ka_state_validate_runtime_dir "$target_dir"; then
            rm -rf -- "$target_dir"
        fi
        ka_error 'could not copy target message rotation'
        return "$copy_rc"
    fi
    ka_request_read_scalar "$request_dir/main_interval" 64 || return 1
    main_interval=$REPLY
    ka_request_read_scalar "$request_dir/secondary_interval" 64 || return 1
    secondary_interval=$REPLY

    ka_state_register_uuid "$uuid"
    KA_T_BACKEND[$uuid]=${KA_D_BACKEND[$uuid]:-konsole}
    KA_T_TYPE[$uuid]=${KA_D_TYPE[$uuid]}
    KA_T_NAME[$uuid]=${KA_D_NAME[$uuid]}
    KA_T_DIR[$uuid]=${KA_D_DIR[$uuid]}
    KA_T_SERVICE[$uuid]=${KA_D_SERVICE[$uuid]-}
    KA_T_PATH[$uuid]=${KA_D_PATH[$uuid]-}
    KA_T_TERM_PID[$uuid]=${KA_D_TERM_PID[$uuid]-}
    KA_T_AI_PID[$uuid]=${KA_D_AI_PID[$uuid]-}
    KA_T_AI_START[$uuid]=${KA_D_AI_START[$uuid]-}
    KA_T_ORCA_HANDLE[$uuid]=${KA_D_ORCA_HANDLE[$uuid]-}
    KA_T_ORCA_PTY[$uuid]=${KA_D_ORCA_PTY[$uuid]-}
    KA_T_ORCA_INCARNATION[$uuid]=${KA_D_ORCA_INCARNATION[$uuid]-}
    KA_T_ORCA_WORKTREE[$uuid]=${KA_D_ORCA_WORKTREE[$uuid]-}
    KA_T_ORCA_RUNTIME[$uuid]=${KA_D_ORCA_RUNTIME[$uuid]-}
    KA_T_ORCA_HOST[$uuid]=${KA_D_ORCA_HOST[$uuid]-}
    KA_T_ORCA_TAB[$uuid]=${KA_D_ORCA_TAB[$uuid]-}
    KA_T_ORCA_LEAF[$uuid]=${KA_D_ORCA_LEAF[$uuid]-}
    KA_T_ORCA_AGENT[$uuid]=${KA_D_ORCA_AGENT[$uuid]-}
    KA_T_STATUS[$uuid]=ACTIVE
    ka_request_read_scalar "$request_dir/delivery_mode" 64 || return 1
    KA_T_MODE[$uuid]=$REPLY
    ka_request_read_scalar "$request_dir/notifications" 64 || return 1
    KA_T_NOTIFY[$uuid]=$REPLY
    KA_T_MAIN_INTERVAL[$uuid]=$main_interval
    KA_T_MAIN_REMAIN[$uuid]=$main_interval
    KA_T_MAIN_INDEX[$uuid]=0
    ka_request_read_scalar "$request_dir/secondary_enabled" 64 || return 1
    KA_T_SECONDARY_ENABLED[$uuid]=$REPLY
    KA_T_SECONDARY_INTERVAL[$uuid]=$secondary_interval
    KA_T_SECONDARY_REMAIN[$uuid]=$secondary_interval
    ka_tunable KEEPALIVE_MAX_MESSAGE_LENGTH 2000
    max_len=$REPLY
    ka_request_read_scalar "$request_dir/secondary_message" "$max_len" || return 1
    KA_T_SECONDARY_MESSAGE[$uuid]=$REPLY
    KA_T_LAST_SEEN[$uuid]=$(ka_now_full)
    KA_T_REASON[$uuid]=''
    KA_T_LAST_DELIVERY_TIME[$uuid]=''
    KA_T_LAST_DELIVERY_EVENT[$uuid]=''
    KA_T_LAST_DELIVERY_RESULT[$uuid]=''
    KA_T_LAST_DELIVERY_DETAIL[$uuid]=''
    KA_T_STRIKES[$uuid]=0
    KA_T_PENDING_SUBMIT[$uuid]=0
    KA_T_SECONDARY_DONE[$uuid]=0

    if ! ka_state_save_target "$uuid"; then
        ka_state_delete_target "$uuid" || true
        ka_error 'could not save target runtime state'
        return 1
    fi
    if ! ka_profile_update_from_request "$request_dir"; then
        ka_state_delete_target "$uuid" || true
        [[ -n ${KA_LAST_ERROR:-} ]] || ka_error 'could not update the persistent profile'
        return 1
    fi
    ka_log_event "$uuid" CREATED "${KA_T_TYPE[$uuid]} / ${KA_T_NAME[$uuid]}" ACTIVE
}

# Role: Reconfigure one existing target and optionally update the single global profile.
# Applying configuration deliberately resets that target's main/secondary countdowns. An
# absent profile_update field preserves the wizard's historical default of updating it.
ka_state_configure_target() {
    local uuid=$1 request_dir=$2
    ka_state_has_target "$uuid" || { ka_error 'unknown keep-alive target'; return 1; }
    [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || { ka_error 'unavailable targets cannot be reconfigured'; return 1; }
    ka_profile_validate_request "$request_dir" || return 1

    local profile_update=1
    if [[ -e $request_dir/profile_update || -L $request_dir/profile_update ]]; then
        ka_request_read_scalar "$request_dir/profile_update" 64 || {
            ka_error 'profile update policy is missing or not a regular file'
            return 1
        }
        profile_update=$REPLY
        [[ $profile_update == 0 || $profile_update == 1 ]] || {
            ka_error 'profile update policy must be 0 or 1'
            return 1
        }
    fi

    local rollback_dir failure
    local old_mode=${KA_T_MODE[$uuid]} old_notifications=${KA_T_NOTIFY[$uuid]}
    local old_main_interval=${KA_T_MAIN_INTERVAL[$uuid]} old_main_remaining=${KA_T_MAIN_REMAIN[$uuid]}
    local old_main_index=${KA_T_MAIN_INDEX[$uuid]}
    local old_secondary_enabled=${KA_T_SECONDARY_ENABLED[$uuid]}
    local old_secondary_interval=${KA_T_SECONDARY_INTERVAL[$uuid]}
    local old_secondary_remaining=${KA_T_SECONDARY_REMAIN[$uuid]}
    local old_secondary_done=${KA_T_SECONDARY_DONE[$uuid]:-0}
    local old_secondary_message=${KA_T_SECONDARY_MESSAGE[$uuid]-}
    # Applying a configuration marks any owed submit STALE; a rollback restores the old
    # rotation, so it must restore the owner too or its completion would stop advancing it.
    local old_pending_submit=${KA_T_PENDING_SUBMIT[$uuid]:-0}
    rollback_dir=$(mktemp -d "$KA_RUNTIME_DIR/configure.staged.XXXXXX") \
        || { ka_error 'could not create configuration rollback state'; return 1; }
    if ! ka_state_copy_target_to_request "$uuid" "$rollback_dir"; then
        rm -rf -- "$rollback_dir"
        ka_error 'could not snapshot the current target configuration'
        return 1
    fi
    if ! ka_state_apply_request_configuration "$uuid" "$request_dir"; then
        failure='could not save target runtime state'
        if ! ka_state_restore_configuration "$uuid" "$rollback_dir" \
            "$old_mode" "$old_notifications" "$old_main_interval" "$old_main_remaining" \
            "$old_main_index" "$old_secondary_enabled" "$old_secondary_interval" \
            "$old_secondary_remaining" "$old_secondary_done" "$old_secondary_message"; then
            failure+='; restoring the previous target configuration also failed'
        else
            KA_T_PENDING_SUBMIT[$uuid]=$old_pending_submit
            ka_state_save_target "$uuid" || ka_state_mark_dirty "$uuid"
        fi
        rm -rf -- "$rollback_dir"
        ka_error "$failure"
        return 1
    fi
    if ((profile_update == 1)) && ! ka_profile_update_from_request "$request_dir"; then
        failure=${KA_LAST_ERROR:-'could not update the persistent profile'}
        if ! ka_state_restore_configuration "$uuid" "$rollback_dir" \
            "$old_mode" "$old_notifications" "$old_main_interval" "$old_main_remaining" \
            "$old_main_index" "$old_secondary_enabled" "$old_secondary_interval" \
            "$old_secondary_remaining" "$old_secondary_done" "$old_secondary_message"; then
            failure+='; restoring the previous target configuration also failed'
        else
            KA_T_PENDING_SUBMIT[$uuid]=$old_pending_submit
            ka_state_save_target "$uuid" || ka_state_mark_dirty "$uuid"
        fi
        rm -rf -- "$rollback_dir"
        ka_error "$failure"
        return 1
    fi
    rm -rf -- "$rollback_dir"
    ka_log_event "$uuid" CONFIG 'configuration updated; countdowns reset' OK
}

# Role: Permanently remove one keep-alive runtime record and its independent event history.
ka_state_delete_target() {
    local uuid=$1 dir
    ka_state_has_target "$uuid" || return 1
    ka_state_target_dir "$uuid"; dir=$REPLY
    ka_state_validate_runtime_dir "$dir" \
        || { ka_error 'target runtime directory is unsafe; refusing recursive removal'; return 1; }
    # Checked: an unchecked failure here forgot the target in memory and answered OK while
    # its checkpoint stayed on disk, to be reloaded as a live keep-alive on the next start.
    rm -rf -- "$dir" || { ka_error 'could not remove target runtime state'; return 1; }
    ka_log_delete "$uuid"
    ka_state_unregister_uuid "$uuid"
    unset 'KA_T_BACKEND[$uuid]' 'KA_T_TYPE[$uuid]' 'KA_T_NAME[$uuid]' 'KA_T_DIR[$uuid]' 'KA_T_SERVICE[$uuid]'
    unset 'KA_T_PATH[$uuid]' 'KA_T_TERM_PID[$uuid]' 'KA_T_AI_PID[$uuid]' 'KA_T_AI_START[$uuid]'
    unset 'KA_T_ORCA_HANDLE[$uuid]' 'KA_T_ORCA_PTY[$uuid]' 'KA_T_ORCA_INCARNATION[$uuid]'
    unset 'KA_T_ORCA_WORKTREE[$uuid]' 'KA_T_ORCA_RUNTIME[$uuid]' 'KA_T_ORCA_HOST[$uuid]'
    unset 'KA_T_ORCA_TAB[$uuid]' 'KA_T_ORCA_LEAF[$uuid]' 'KA_T_ORCA_AGENT[$uuid]'
    unset 'KA_T_STATUS[$uuid]' 'KA_T_MODE[$uuid]' 'KA_T_NOTIFY[$uuid]' 'KA_T_MAIN_INTERVAL[$uuid]'
    unset 'KA_T_MAIN_REMAIN[$uuid]' 'KA_T_MAIN_INDEX[$uuid]' 'KA_T_SECONDARY_ENABLED[$uuid]'
    unset 'KA_T_SECONDARY_INTERVAL[$uuid]' 'KA_T_SECONDARY_REMAIN[$uuid]' 'KA_T_SECONDARY_MESSAGE[$uuid]'
    unset 'KA_T_LAST_SEEN[$uuid]' 'KA_T_REASON[$uuid]' 'KA_T_STRIKES[$uuid]' 'KA_T_DIRTY[$uuid]'
    unset 'KA_T_LAST_DELIVERY_TIME[$uuid]' 'KA_T_LAST_DELIVERY_EVENT[$uuid]'
    unset 'KA_T_LAST_DELIVERY_RESULT[$uuid]' 'KA_T_LAST_DELIVERY_DETAIL[$uuid]'
    unset 'KA_T_PENDING_SUBMIT[$uuid]' 'KA_T_SECONDARY_DONE[$uuid]'
}

# Role: Toggle ACTIVE/PAUSED while preserving each countdown exactly.
ka_state_toggle_pause() {
    local uuid=$1 old new
    ka_state_has_target "$uuid" || return 1
    old=${KA_T_STATUS[$uuid]}
    case $old in
        ACTIVE) new=PAUSED ;;
        PAUSED) new=ACTIVE ;;
        *)
            return 2
            ;;
    esac
    KA_T_STATUS[$uuid]=$new
    if ! ka_state_save_target "$uuid"; then
        KA_T_STATUS[$uuid]=$old
        ka_error 'could not save target pause state'
        return 1
    fi
    if [[ $new == PAUSED ]]; then
        ka_log_event "$uuid" STATE paused PAUSED
    else
        ka_log_event "$uuid" STATE resumed ACTIVE
    fi
}

# Role: Toggle the whole target between MESSAGE+ENTER and ENTER_ONLY delivery.
ka_state_toggle_mode() {
    local uuid=$1 old new
    ka_state_has_target "$uuid" || return 1
    [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || return 2
    old=${KA_T_MODE[$uuid]}
    if [[ $old == MESSAGE_ENTER ]]; then new=ENTER_ONLY; else new=MESSAGE_ENTER; fi
    KA_T_MODE[$uuid]=$new
    if ! ka_state_save_target "$uuid"; then
        KA_T_MODE[$uuid]=$old
        ka_error 'could not save target delivery mode'
        return 1
    fi
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
    if ! ka_state_save_target "$uuid"; then
        KA_T_MODE[$uuid]=$old
        ka_error 'could not save target delivery mode'
        return 1
    fi
    ka_log_event "$uuid" MODE "$old -> $mode" OK
}

# Role: Reset only the selected target's main countdown to its configured interval.
ka_state_reset_main() {
    local uuid=$1 old
    ka_state_has_target "$uuid" || return 1
    [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || return 2
    old=${KA_T_MAIN_REMAIN[$uuid]}
    KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
    if ! ka_state_save_target "$uuid"; then
        KA_T_MAIN_REMAIN[$uuid]=$old
        ka_error 'could not save the reset main timer'
        return 1
    fi
    ka_log_event "$uuid" TIMER 'main timer reset' OK
}

# Role: Transition a target to sticky UNAVAILABLE state while retaining all state/logs.
ka_state_mark_unavailable() {
    local uuid=$1 reason=$2 previous previous_reason previous_strikes previous_last_seen
    ka_state_has_target "$uuid" || return 1
    previous=${KA_T_STATUS[$uuid]}
    [[ $previous == UNAVAILABLE ]] && return 0
    previous_reason=${KA_T_REASON[$uuid]-}
    previous_strikes=${KA_T_STRIKES[$uuid]-0}
    previous_last_seen=${KA_T_LAST_SEEN[$uuid]-}
    KA_T_STATUS[$uuid]=UNAVAILABLE
    KA_T_REASON[$uuid]=$reason
    KA_T_STRIKES[$uuid]=0
    KA_T_LAST_SEEN[$uuid]=$(ka_now_full)
    if ! ka_state_save_target "$uuid"; then
        KA_T_STATUS[$uuid]=$previous
        KA_T_REASON[$uuid]=$previous_reason
        KA_T_STRIKES[$uuid]=$previous_strikes
        KA_T_LAST_SEEN[$uuid]=$previous_last_seen
        ka_error 'could not save unavailable target state'
        return 1
    fi
    ka_log_event "$uuid" TARGET "$reason" UNAVAILABLE
    ka_notify_target_lost "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$reason"
}

# Role: Validate one target against its backend's current discovery snapshot.
# Pre-send validation deliberately keeps using the live adapter path; a send must never
# rely on a snapshot.
ka_state_validate_from_discovery() {
    local uuid=$1 start age max_age backend stamp
    backend=${KA_T_BACKEND[$uuid]:-konsole}
    # Discovery can back off to tens of seconds when nobody is watching, and validating
    # against a snapshot that old would delay noticing a target-side change. Orca listing
    # is already authoritative for live handles and is reused through the idle discovery
    # window; strict pre-send validation remains live in every case.
    case $backend in
        konsole)
            ka_tunable KEEPALIVE_SNAPSHOT_MAX_AGE 10
            max_age=$REPLY
            stamp=${KA_DISCOVERY_STAMP_KONSOLE:-${KA_DISCOVERY_STAMP:-0}}
            ;;
        orca)
            ka_tunable KEEPALIVE_ORCA_SNAPSHOT_MAX_AGE 35
            max_age=$REPLY
            stamp=${KA_DISCOVERY_STAMP_ORCA:-0}
            ;;
        *) return 22 ;;
    esac
    ka_now_monotonic || return 1
    age=$((REPLY - stamp))
    # A negative age means the snapshot predates a monotonic rollback: its stamp comes from
    # a clock reading that no longer orders against now, so it cannot prove freshness.
    ((age >= 0 && age <= max_age)) || return 1
    [[ ${KA_D_BACKEND[$uuid]:-konsole} == "$backend" ]] || return 1
    # Return 1 only for "no usable snapshot", which is the caller's signal to fall back
    # to a live call. Every field must be present before the snapshot can be trusted.
    case $backend in
        konsole)
            [[ -n ${KA_D_TERM_PID[$uuid]+x} && -n ${KA_D_FG_PID[$uuid]+x} ]] || return 1
            [[ ${KA_D_TERM_PID[$uuid]} == "${KA_T_TERM_PID[$uuid]}" ]] || return 11
            [[ -d /proc/${KA_T_AI_PID[$uuid]} ]] || return 12
            start=''
            ka_proc_starttime_set "${KA_T_AI_PID[$uuid]}" && start=$REPLY
            [[ $start == "${KA_T_AI_START[$uuid]}" ]] || return 13
            [[ ${KA_D_FG_PID[$uuid]} =~ ^[0-9]+$ ]] || return 14
            ka_process_is_descendant_of "${KA_D_FG_PID[$uuid]}" "${KA_T_AI_PID[$uuid]}" || return 15
            ;;
        orca)
            [[ -n ${KA_D_ORCA_HANDLE[$uuid]+x} && -n ${KA_D_ORCA_INCARNATION[$uuid]+x} ]] || return 1
            [[ ${KA_D_ORCA_RUNTIME[$uuid]} == "${KA_T_ORCA_RUNTIME[$uuid]}" ]] || return 11
            [[ ${KA_D_ORCA_HANDLE[$uuid]} == "${KA_T_ORCA_HANDLE[$uuid]}" ]] || return 10
            [[ ${KA_D_ORCA_INCARNATION[$uuid]} == "${KA_T_ORCA_INCARNATION[$uuid]}" ]] || return 12
            [[ ${KA_D_ORCA_PTY[$uuid]} == "${KA_T_ORCA_PTY[$uuid]}" ]] || return 13
            [[ ${KA_D_ORCA_WORKTREE[$uuid]} == "${KA_T_ORCA_WORKTREE[$uuid]}" \
                && ${KA_D_ORCA_HOST[$uuid]} == "${KA_T_ORCA_HOST[$uuid]}" ]] || return 14
            [[ ${KA_D_ORCA_TAB[$uuid]} == "${KA_T_ORCA_TAB[$uuid]}" \
                && ${KA_D_ORCA_LEAF[$uuid]} == "${KA_T_ORCA_LEAF[$uuid]}" ]] || return 16
            [[ ${KA_D_ORCA_AGENT[$uuid]} == "${KA_T_ORCA_AGENT[$uuid]}" ]] || return 15
            ;;
    esac
    return 0
}

# Role: Validate every non-unavailable monitored target and update last-seen metadata.
# Transient failures are debounced rather than ignored: a backend that never comes back
# still ends in UNAVAILABLE, but a momentary outage does not destroy identity immediately.
ka_state_validate_targets() {
    local uuid rc reason limit strikes backend seen_at failed=0
    ((${#KA_T_UUIDS[@]} > 0)) || return 0
    # Both read once per pass with builtins: this runs every health interval, and each
    # command substitution here used to fork, per pass and per target respectively.
    ka_tunable KEEPALIVE_VALIDATION_STRIKES 5; limit=$REPLY
    printf -v seen_at '%(%F %T)T' -1
    for uuid in "${KA_T_UUIDS[@]}"; do
        [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || continue
        # Prefer the snapshot; fall back to a live call only for targets discovery
        # did not see this cycle.
        if ka_state_validate_from_discovery "$uuid"; then
            rc=0
        elif rc=$?; ((rc != 1)); then
            :
        elif ka_transport_validate_target "$uuid"; then
            rc=0
        else
            rc=$?
        fi
        if ((rc == 0)); then
            KA_T_LAST_SEEN[$uuid]=$seen_at
            KA_T_STRIKES[$uuid]=0
        else
            backend=${KA_T_BACKEND[$uuid]:-konsole}
            reason=$(ka_transport_validation_reason "$backend" "$rc")
            if ka_transport_validation_is_transient "$backend" "$rc"; then
                if ! ka_transport_validation_consumes_strike "$backend" "$rc"; then
                    KA_T_STRIKES[$uuid]=0
                    continue
                fi
                strikes=$(( ${KA_T_STRIKES[$uuid]:-0} + 1 ))
                KA_T_STRIKES[$uuid]=$strikes
                ((strikes >= limit)) || continue
                reason="$reason (${strikes} consecutive attempts)"
            fi
            if ! ka_state_mark_unavailable "$uuid" "$reason"; then
                failed=1
                ka_warn "could not save unavailable target state for $uuid; validation will retry"
            fi
        fi
    done
    return "$failed"
}

# Role: Publish one atomic merged index containing monitored and currently AVAILABLE sessions.
#
# The payload is built in memory and compared with the bytes actually published: the daemon
# republishes every second while a client watches, and most of those were identical
# renames. Clients compare content, never mtime, so skipping an identical write is
# invisible to them. Comparing the file itself, read with a builtin, rather than a
# remembered copy means a deleted, replaced, truncated, or unreadable index is always
# rewritten.
ka_state_publish_index() {
    local uuid status payload='' row published
    local type name directory last reason next_main next_secondary
    local delivery_time delivery_event delivery_result delivery_detail publication_epoch
    printf -v publication_epoch '%(%s)T' -1
    for uuid in "${KA_T_UUIDS[@]}"; do
        status=${KA_T_STATUS[$uuid]}
        ka_single_line "${KA_T_TYPE[$uuid]}";       type=$REPLY
        ka_single_line "${KA_T_NAME[$uuid]}";       name=$REPLY
        ka_single_line "${KA_T_DIR[$uuid]}";        directory=$REPLY
        ka_single_line "${KA_T_LAST_SEEN[$uuid]-}"; last=$REPLY
        ka_single_line "${KA_T_REASON[$uuid]-}";    reason=$REPLY
        next_main=''; next_secondary=''
        if [[ $status == ACTIVE ]]; then
            printf -v next_main '%(%F %T)T' "$((publication_epoch + ${KA_T_MAIN_REMAIN[$uuid]:-0}))"
            if [[ ${KA_T_SECONDARY_ENABLED[$uuid]:-0} == 1 \
                && ${KA_T_SECONDARY_DONE[$uuid]:-0} != 1 ]]; then
                printf -v next_secondary '%(%F %T)T' \
                    "$((publication_epoch + ${KA_T_SECONDARY_REMAIN[$uuid]:-0}))"
            fi
        fi
        ka_single_line "${KA_T_LAST_DELIVERY_TIME[$uuid]-}";   delivery_time=$REPLY
        ka_single_line "${KA_T_LAST_DELIVERY_EVENT[$uuid]-}";  delivery_event=$REPLY
        ka_single_line "${KA_T_LAST_DELIVERY_RESULT[$uuid]-}"; delivery_result=$REPLY
        ka_single_line "${KA_T_LAST_DELIVERY_DETAIL[$uuid]-}"; delivery_detail=$REPLY
        printf -v row '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$uuid" "$type" "$name" "$directory" "$status" "${KA_T_MAIN_REMAIN[$uuid]}" \
            "${KA_T_MAIN_INTERVAL[$uuid]}" "${KA_T_SECONDARY_ENABLED[$uuid]}" \
            "${KA_T_SECONDARY_REMAIN[$uuid]}" "${KA_T_SECONDARY_INTERVAL[$uuid]}" \
            "${KA_T_MODE[$uuid]}" "${KA_T_NOTIFY[$uuid]}" "$last" "$reason" \
            "${KA_T_BACKEND[$uuid]:-konsole}" "$next_main" "$next_secondary" \
            "$delivery_time" "$delivery_event" "$delivery_result" "$delivery_detail"
        payload+=$row
    done

    for uuid in "${KA_D_UUIDS[@]}"; do
        ka_state_has_target "$uuid" && continue
        ka_single_line "${KA_D_TYPE[$uuid]}"; type=$REPLY
        ka_single_line "${KA_D_NAME[$uuid]}"; name=$REPLY
        ka_single_line "${KA_D_DIR[$uuid]}";  directory=$REPLY
        printf -v row '%s\t%s\t%s\t%s\tAVAILABLE\t0\t0\t0\t0\t0\t\t0\t\t\t%s\t\t\t\t\t\t\n' \
            "$uuid" "$type" "$name" "$directory" "${KA_D_BACKEND[$uuid]:-konsole}"
        payload+=$row
    done

    if [[ -f $KA_INDEX_FILE && ! -L $KA_INDEX_FILE && -O $KA_INDEX_FILE && -r $KA_INDEX_FILE ]]; then
        published=''
        IFS= read -r -d '' published <"$KA_INDEX_FILE" 2>/dev/null || true
        [[ $published == "$payload" ]] && return 0
    fi
    ka_atomic_write_value "$KA_INDEX_FILE" "$payload"
}

# Role: Read one scalar field from a persisted target state file for client-side rendering.
ka_state_read_field() {
    local uuid=$1 wanted=$2 dir file key value
    ka_state_target_dir "$uuid"; dir=$REPLY
    file="$dir/state.tsv"
    [[ -f $file && ! -L $file && -O $file && -r $file ]] || return 1
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
    local uuid=$1 request_dir=$2 dir secondary_file='' secondary_path secondary_message
    local main_interval secondary_enabled secondary_interval notifications delivery_mode request_parent
    ka_state_target_dir "$uuid"; dir=$REPLY
    ka_state_validate_runtime_dir "$dir" || return 1
    [[ -f $dir/state.tsv && ! -L $dir/state.tsv && -O $dir/state.tsv && -r $dir/state.tsv ]] \
        || return 1
    if secondary_file=$(ka_state_read_field "$uuid" secondary_message_file); then
        [[ $secondary_file =~ ^secondary_message\.[0-9]+\.[0-9]+$ ]] || return 1
        secondary_path="$dir/$secondary_file"
    else
        secondary_path="$dir/secondary_message"
    fi
    [[ -f $secondary_path && ! -L $secondary_path && -O $secondary_path && -r $secondary_path ]] \
        || return 1
    ka_profile_validate_main_messages "$dir/messages" >/dev/null 2>&1 || return 1
    main_interval=$(ka_state_read_field "$uuid" main_interval) || return 1
    secondary_enabled=$(ka_state_read_field "$uuid" secondary_enabled) || return 1
    # Bounded exactly as the checkpoint loader reads it: a disabled secondary that is
    # oversized or unreadable seeds as empty (it is never sent), an enabled one fails.
    local max_len
    ka_tunable KEEPALIVE_MAX_MESSAGE_LENGTH 2000
    max_len=$REPLY
    if ka_request_read_scalar "$secondary_path" "$max_len"; then
        secondary_message=$REPLY
    elif [[ $secondary_enabled == 0 ]]; then
        secondary_message=''
    else
        return 1
    fi
    secondary_interval=$(ka_state_read_field "$uuid" secondary_interval) || return 1
    notifications=$(ka_state_read_field "$uuid" notifications) || return 1
    delivery_mode=$(ka_state_read_field "$uuid" mode) || return 1
    if [[ ! -e $request_dir && ! -L $request_dir ]]; then
        request_parent=${request_dir%/*}
        ka_state_validate_runtime_dir "$request_parent" || return 1
        mkdir -- "$request_dir" || return 1
    fi
    ka_state_validate_runtime_dir "$request_dir" || return 1
    if [[ -e $request_dir/messages || -L $request_dir/messages ]]; then
        ka_state_validate_runtime_dir "$request_dir/messages" || return 1
        rm -rf -- "$request_dir/messages" || return 1
    fi
    mkdir -- "$request_dir/messages" || return 1
    ka_state_validate_runtime_dir "$request_dir/messages" || return 1
    ka_write_scalar "$request_dir/main_interval" "$main_interval" || return 1
    ka_write_scalar "$request_dir/secondary_enabled" "$secondary_enabled" || return 1
    ka_write_scalar "$request_dir/secondary_interval" "$secondary_interval" || return 1
    ka_write_scalar "$request_dir/secondary_message" "$secondary_message" || return 1
    ka_write_scalar "$request_dir/notifications" "$notifications" || return 1
    ka_write_scalar "$request_dir/delivery_mode" "$delivery_mode" || return 1
    cp -f -- "$dir/messages"/[0-9][0-9][0-9] "$request_dir/messages/" || return 1
}
