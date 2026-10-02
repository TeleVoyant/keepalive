#!/usr/bin/env bash
# Persistent single-profile defaults used when creating/configuring keep-alives.

# Role: Acquire the private profile lock, serializing readers with directory swaps.
ka_profile_lock_acquire() {
    local lockfile fd_path resolved rc=0 had_noclobber=0
    KA_PROFILE_LOCK_FD=''
    lockfile="$KA_CONFIG_DIR/profile.lock"
    if [[ ! -e $KA_CONFIG_DIR && ! -L $KA_CONFIG_DIR ]]; then
        mkdir -p -- "$KA_CONFIG_DIR" || {
            ka_error "could not create profile lock directory: $KA_CONFIG_DIR"
            return 1
        }
    fi
    [[ -d $KA_CONFIG_DIR && ! -L $KA_CONFIG_DIR && -O $KA_CONFIG_DIR ]] || {
        ka_error "refusing unsafe profile lock directory: $KA_CONFIG_DIR"
        return 1
    }
    if [[ -L $lockfile || (-e $lockfile && ! -f $lockfile) ]]; then
        ka_error "refusing unsafe profile lock: $lockfile"
        return 1
    fi
    # flock needs only an open descriptor, not write access: an existing lock opens
    # read-only so a read-only profile (0400 files, 0500 directory) still snapshots.
    if [[ -e $lockfile ]]; then
        if ! exec {KA_PROFILE_LOCK_FD}<"$lockfile"; then
            ka_error "could not open profile lock: $lockfile"
            return 1
        fi
    else
        [[ $- == *C* ]] && had_noclobber=1
        set -o noclobber
        if { exec {KA_PROFILE_LOCK_FD}>"$lockfile"; }; then
            :
        else
            rc=$?
            ((had_noclobber == 1)) || set +o noclobber
            if [[ -L $lockfile || ! -f $lockfile || ! -O $lockfile ]] \
                || ! exec {KA_PROFILE_LOCK_FD}<"$lockfile"; then
                ka_error "could not safely create profile lock: $lockfile (status $rc)"
                return 1
            fi
        fi
        ((had_noclobber == 1)) || set +o noclobber
    fi
    fd_path="/proc/$$/fd/$KA_PROFILE_LOCK_FD"
    rc=0
    resolved=$(readlink -f -- "$fd_path") || rc=$?
    if ((rc != 0)) || [[ $resolved != "$lockfile" || ! -f $fd_path || ! -O $fd_path ]] \
        || ! chmod 600 "$fd_path" 2>/dev/null; then
        { exec {KA_PROFILE_LOCK_FD}>&-; } 2>/dev/null || true
        KA_PROFILE_LOCK_FD=''
        ka_error "profile lock descriptor is unsafe: $lockfile"
        return 1
    fi
    if ! flock "$KA_PROFILE_LOCK_FD"; then
        { exec {KA_PROFILE_LOCK_FD}>&-; } 2>/dev/null || true
        KA_PROFILE_LOCK_FD=''
        ka_error "could not acquire profile lock: $lockfile"
        return 1
    fi
}

# Role: Release the descriptor held for the profile reader/writer lock.
ka_profile_lock_release() {
    local fd=${KA_PROFILE_LOCK_FD:-}
    if [[ -n $fd ]]; then
        { exec {fd}>&-; } 2>/dev/null || true
    fi
    KA_PROFILE_LOCK_FD=''
}

# Role: Create or validate one owned regular profile scalar without following a link/FIFO.
ka_profile_ensure_scalar() {
    local path=$1 default=$2
    if [[ -e $path || -L $path ]]; then
        [[ -f $path && ! -L $path && -O $path ]] || {
            ka_error "refusing unsafe profile scalar: $path"
            return 1
        }
    else
        ka_write_scalar "$path" "$default" || return 1
    fi
}

# Role: Create the one global profile with safe defaults while the caller owns the lock.
ka_profile_init_defaults_unlocked() {
    ka_ensure_config_dirs || return 1
    [[ -d $KA_PROFILE_DIR/messages && ! -L $KA_PROFILE_DIR/messages && -O $KA_PROFILE_DIR/messages ]] \
        || { ka_error 'profile messages path is not a private directory'; return 1; }
    ka_profile_ensure_scalar "$KA_PROFILE_DIR/main_interval" 1500 || return 1
    ka_profile_ensure_scalar "$KA_PROFILE_DIR/secondary_enabled" 0 || return 1
    ka_profile_ensure_scalar "$KA_PROFILE_DIR/secondary_interval" 600 || return 1
    ka_profile_ensure_scalar "$KA_PROFILE_DIR/secondary_message" 'Continue if there is unfinished work.' || return 1
    ka_profile_ensure_scalar "$KA_PROFILE_DIR/notifications" 0 || return 1
    ka_profile_ensure_scalar "$KA_PROFILE_DIR/delivery_mode" MESSAGE_ENTER || return 1
    ka_cleanup_staged_dirs "$KA_CONFIG_DIR"
    if ! compgen -G "$KA_PROFILE_DIR/messages/[0-9][0-9][0-9]" >/dev/null; then
        ka_write_scalar "$KA_PROFILE_DIR/messages/001" 'ping' || return 1
    fi
}

# Role: Initialize defaults while holding the same lock used by readers and swaps.
ka_profile_init_defaults() {
    local rc=0
    ka_profile_lock_acquire || return 1
    ka_profile_init_defaults_unlocked || rc=$?
    ka_profile_lock_release
    return "$rc"
}

# Role: Copy one bounded profile scalar through the same descriptor checks as requests.
ka_profile_copy_scalar() {
    local source=$1 destination=$2 max=${3:-128}
    ka_request_read_scalar "$source" "$max" || return 1
    ka_write_scalar "$destination" "$REPLY"
}

# Role: Create one request messages/ directory a single level deep and validate it.
ka_profile_request_messages_dir() {
    local dir="$1/messages"
    if [[ ! -e $dir && ! -L $dir ]]; then
        mkdir -- "$dir" || return 1
    fi
    ka_request_validate_dir "$dir"
}

# Role: Copy current profile values into a request directory while holding the profile lock.
ka_profile_copy_to_request_unlocked() {
    local request_dir=$1 max_len file name
    # Create only the final level, then validate before the first write: mkdir -p would
    # follow a planted symlink and redirect every copied file. The validation also
    # rejects a symlinked ancestor, since the path must already be canonical.
    if [[ ! -e $request_dir && ! -L $request_dir ]]; then
        # Validate the parent first: through a symlinked ancestor even this one mkdir
        # would create the directory at the link's target before the check below fails.
        ka_request_validate_dir "${request_dir%/*}" || return 1
        mkdir -- "$request_dir" || return 1
    fi
    ka_request_validate_dir "$request_dir" || return 1
    ka_profile_request_messages_dir "$request_dir" || return 1
    ka_profile_copy_scalar "$KA_PROFILE_DIR/main_interval" "$request_dir/main_interval" 64 || return 1
    ka_profile_copy_scalar "$KA_PROFILE_DIR/secondary_enabled" "$request_dir/secondary_enabled" 64 || return 1
    ka_profile_copy_scalar "$KA_PROFILE_DIR/secondary_interval" "$request_dir/secondary_interval" 64 || return 1
    ka_tunable KEEPALIVE_MAX_MESSAGE_LENGTH 2000
    max_len=$REPLY
    ka_request_copy_file "$KA_PROFILE_DIR/secondary_message" "$request_dir/secondary_message" "$max_len" || return 1
    ka_profile_copy_scalar "$KA_PROFILE_DIR/notifications" "$request_dir/notifications" 64 || return 1
    ka_profile_copy_scalar "$KA_PROFILE_DIR/delivery_mode" "$request_dir/delivery_mode" 64 || return 1
    rm -rf -- "$request_dir/messages" || return 1
    ka_profile_request_messages_dir "$request_dir" || return 1
    shopt -s nullglob
    local -a files=("$KA_PROFILE_DIR/messages"/[0-9][0-9][0-9])
    shopt -u nullglob
    ((${#files[@]} > 0)) || return 1
    for file in "${files[@]}"; do
        name=${file##*/}
        ka_request_copy_file "$file" "$request_dir/messages/$name" "$max_len" || return 1
    done
}

# Role: Copy a stable profile snapshot into a request directory under the private lock.
ka_profile_copy_to_request() {
    local request_dir=$1 rc=0
    ka_profile_lock_acquire || return 1
    ka_profile_init_defaults_unlocked || rc=$?
    if ((rc == 0)); then
        ka_profile_copy_to_request_unlocked "$request_dir" || rc=$?
    fi
    ka_profile_lock_release
    return "$rc"
}

# Role: Replace the single persistent profile with validated values from one request.
ka_profile_update_from_request_unlocked() {
    local request_dir=$1
    local staged="$KA_CONFIG_DIR/profile.staged.$$"
    local max_len file name
    ka_profile_validate_request "$request_dir" || return 1
    ka_ensure_config_dirs || return 1

    # Stage the complete profile, not only its messages. A failed scalar write must not
    # leave defaults from two generations mixed together while CREATE still reports OK.
    rm -rf -- "$staged" || return 1
    mkdir -p "$staged/messages" \
        || { ka_error 'could not stage the persistent profile'; return 1; }
    chmod 700 "$staged" "$staged/messages" 2>/dev/null \
        || { rm -rf -- "$staged"; ka_error 'could not secure the staged persistent profile'; return 1; }
    ka_profile_copy_scalar "$request_dir/main_interval" "$staged/main_interval" 64 \
        || { rm -rf -- "$staged"; ka_error 'could not stage the persistent profile'; return 1; }
    ka_profile_copy_scalar "$request_dir/secondary_enabled" "$staged/secondary_enabled" 64 \
        || { rm -rf -- "$staged"; ka_error 'could not stage the persistent profile'; return 1; }
    ka_profile_copy_scalar "$request_dir/secondary_interval" "$staged/secondary_interval" 64 \
        || { rm -rf -- "$staged"; ka_error 'could not stage the persistent profile'; return 1; }
    ka_tunable KEEPALIVE_MAX_MESSAGE_LENGTH 2000
    max_len=$REPLY
    ka_request_copy_file "$request_dir/secondary_message" "$staged/secondary_message" "$max_len" \
        || { rm -rf -- "$staged"; ka_error 'could not stage the persistent profile'; return 1; }
    ka_profile_copy_scalar "$request_dir/notifications" "$staged/notifications" 64 \
        || { rm -rf -- "$staged"; ka_error 'could not stage the persistent profile'; return 1; }
    ka_profile_copy_scalar "$request_dir/delivery_mode" "$staged/delivery_mode" 64 \
        || { rm -rf -- "$staged"; ka_error 'could not stage the persistent profile'; return 1; }
    shopt -s nullglob
    local -a files=("$request_dir/messages"/[0-9][0-9][0-9])
    shopt -u nullglob
    for file in "${files[@]}"; do
        name=${file##*/}
        ka_request_copy_file "$file" "$staged/messages/$name" "$max_len" \
            || { rm -rf -- "$staged"; ka_error 'could not stage the persistent profile'; return 1; }
    done
    chmod 600 "$staged/secondary_message" "$staged/main_interval" \
        "$staged/secondary_enabled" "$staged/secondary_interval" "$staged/notifications" \
        "$staged/delivery_mode" "$staged/messages/"* 2>/dev/null \
        || { rm -rf -- "$staged"; ka_error 'could not secure the staged persistent profile'; return 1; }
    ka_commit_staged_dir "$staged" "$KA_PROFILE_DIR" \
        || { ka_error 'could not commit the persistent profile'; return 1; }
}

# Role: Replace the profile while excluding concurrent readers from every commit step.
ka_profile_update_from_request() {
    local request_dir=$1 rc=0
    ka_profile_lock_acquire || return 1
    ka_profile_update_from_request_unlocked "$request_dir" || rc=$?
    ka_profile_lock_release
    return "$rc"
}

# Role: Validate that main messages form a non-empty contiguous 001..N rotation.
ka_profile_validate_main_messages() {
    local messages_dir=$1
    (
        local file content expected index count max_count max_len
        ka_request_validate_dir "$messages_dir" || {
            ka_error 'main messages path must be a regular directory'
            return 1
        }
        shopt -s nullglob
        local -a files=("$messages_dir"/[0-9][0-9][0-9])
        shopt -u nullglob
        count=${#files[@]}

        ((count > 0)) || {
            ka_error 'at least one non-empty main message is required'
            return 1
        }
        ka_tunable KEEPALIVE_MAX_MESSAGES 64
        max_count=$REPLY
        ((count <= max_count)) || {
            ka_error "main message rotation has $count entries; the limit is $max_count"
            return 1
        }
        ka_tunable KEEPALIVE_MAX_MESSAGE_LENGTH 2000
        max_len=$REPLY

        for ((index=1; index<=count; index++)); do
            printf -v expected '%03d' "$index"
            file="$messages_dir/$expected"
            [[ -e $file ]] || {
                ka_error "main message files must be contiguous from 001 (missing $expected)"
                return 1
            }
            [[ -f $file && ! -L $file && -s $file ]] || {
                ka_error "main message $expected must be a non-empty non-symlink regular file"
                return 1
            }
            ka_request_read_scalar "$file" "$max_len" || {
                ka_error "main message $expected could not be read"
                return 1
            }
            content=$REPLY
            [[ -n $content ]] || {
                ka_error "main message $expected must be a non-empty logical line"
                return 1
            }
        done
    )
}

# Role: Validate configuration files supplied by a TUI create/configure request.
ka_profile_validate_request() {
    local request_dir=$1
    local main_interval secondary_enabled secondary_interval notifications delivery_mode
    local secondary_content max_len
    ka_request_validate_dir "$request_dir" \
        || { ka_error 'configuration path must be a private regular directory'; return 1; }
    ka_request_read_scalar "$request_dir/main_interval" 64 \
        || { ka_error 'configuration scalar is missing or not a regular file'; return 1; }
    main_interval=$REPLY
    ka_request_read_scalar "$request_dir/secondary_enabled" 64 \
        || { ka_error 'configuration scalar is missing or not a regular file'; return 1; }
    secondary_enabled=$REPLY
    ka_request_read_scalar "$request_dir/secondary_interval" 64 \
        || { ka_error 'configuration scalar is missing or not a regular file'; return 1; }
    secondary_interval=$REPLY
    ka_request_read_scalar "$request_dir/notifications" 64 \
        || { ka_error 'configuration scalar is missing or not a regular file'; return 1; }
    notifications=$REPLY
    ka_request_read_scalar "$request_dir/delivery_mode" 64 \
        || { ka_error 'configuration scalar is missing or not a regular file'; return 1; }
    delivery_mode=$REPLY

    ka_is_interval "$main_interval" || { ka_error 'main interval must be 1 to 999999999 seconds'; return 1; }
    [[ $secondary_enabled == 0 || $secondary_enabled == 1 ]] || { ka_error 'secondary_enabled must be 0 or 1'; return 1; }
    ka_is_interval "$secondary_interval" || { ka_error 'secondary interval must be 1 to 999999999 seconds'; return 1; }
    [[ $notifications == 0 || $notifications == 1 ]] || { ka_error 'notifications must be 0 or 1'; return 1; }
    [[ $delivery_mode == MESSAGE_ENTER || $delivery_mode == ENTER_ONLY ]] || { ka_error 'invalid delivery mode'; return 1; }
    ka_tunable KEEPALIVE_MAX_MESSAGE_LENGTH 2000
    max_len=$REPLY
    ka_request_read_scalar "$request_dir/secondary_message" "$max_len" \
        || { ka_error 'secondary message is missing or not a regular file'; return 1; }
    secondary_content=$REPLY
    if [[ $secondary_enabled == 1 ]]; then
        [[ -n $secondary_content ]] || { ka_error 'enabled secondary message cannot be empty'; return 1; }
    fi

    ka_profile_validate_main_messages "$request_dir/messages"
}

# Role: Print one sanitized profile scalar in human-readable maintenance form.
ka_profile_print_value() {
    local label=$1 value=$2
    ka_sanitize_human_set "$value"
    printf '%s=%s\n' "$label" "$REPLY"
}

# Role: Print a stable persistent-profile snapshot while holding the profile lock.
ka_profile_print() {
    local rc=0 value file max_len
    ka_profile_lock_acquire || return 1
    ka_profile_init_defaults_unlocked || rc=$?
    if ((rc == 0)); then
        ka_request_read_scalar "$KA_PROFILE_DIR/main_interval" 64 || rc=$?
        if ((rc == 0)); then ka_profile_print_value main_interval "$REPLY"; fi
        if ((rc == 0)); then
            ka_request_read_scalar "$KA_PROFILE_DIR/secondary_enabled" 64 || rc=$?
            if ((rc == 0)); then ka_profile_print_value secondary_enabled "$REPLY"; fi
        fi
        if ((rc == 0)); then
            ka_request_read_scalar "$KA_PROFILE_DIR/secondary_interval" 64 || rc=$?
            if ((rc == 0)); then ka_profile_print_value secondary_interval "$REPLY"; fi
        fi
        if ((rc == 0)); then
            ka_tunable KEEPALIVE_MAX_MESSAGE_LENGTH 2000
            max_len=$REPLY
            ka_request_read_scalar "$KA_PROFILE_DIR/secondary_message" "$max_len" || rc=$?
            if ((rc == 0)); then ka_profile_print_value secondary_message "$REPLY"; fi
        fi
        if ((rc == 0)); then
            ka_request_read_scalar "$KA_PROFILE_DIR/notifications" 64 || rc=$?
            if ((rc == 0)); then ka_profile_print_value notifications "$REPLY"; fi
        fi
        if ((rc == 0)); then
            ka_request_read_scalar "$KA_PROFILE_DIR/delivery_mode" 64 || rc=$?
            if ((rc == 0)); then ka_profile_print_value delivery_mode "$REPLY"; fi
        fi
        if ((rc == 0)); then
            printf 'messages:\n'
            for file in "$KA_PROFILE_DIR/messages"/[0-9][0-9][0-9]; do
                ka_request_read_scalar "$file" "$max_len" || { rc=$?; break; }
                ka_sanitize_human_set "$REPLY"
                printf '  - %s\n' "$REPLY"
            done
        fi
    fi
    ka_profile_lock_release
    return "$rc"
}
