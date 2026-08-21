#!/usr/bin/env bash
# Persistent single-profile defaults used when creating/configuring keep-alives.

# Role: Create the one global profile with safe defaults when it does not yet exist.
ka_profile_init_defaults() {
    ka_ensure_config_dirs
    [[ -r $KA_PROFILE_DIR/main_interval ]] || ka_write_scalar "$KA_PROFILE_DIR/main_interval" 1500
    [[ -r $KA_PROFILE_DIR/secondary_enabled ]] || ka_write_scalar "$KA_PROFILE_DIR/secondary_enabled" 0
    [[ -r $KA_PROFILE_DIR/secondary_interval ]] || ka_write_scalar "$KA_PROFILE_DIR/secondary_interval" 600
    [[ -r $KA_PROFILE_DIR/secondary_message ]] || ka_write_scalar "$KA_PROFILE_DIR/secondary_message" 'Continue if there is unfinished work.'
    [[ -r $KA_PROFILE_DIR/notifications ]] || ka_write_scalar "$KA_PROFILE_DIR/notifications" 0
    [[ -r $KA_PROFILE_DIR/delivery_mode ]] || ka_write_scalar "$KA_PROFILE_DIR/delivery_mode" MESSAGE_ENTER
    if ! compgen -G "$KA_PROFILE_DIR/messages/[0-9][0-9][0-9]" >/dev/null; then
        mkdir -p "$KA_PROFILE_DIR/messages"
        ka_write_scalar "$KA_PROFILE_DIR/messages/001" 'ping'
    fi
}

# Role: Copy current profile values into a request directory as wizard defaults.
ka_profile_copy_to_request() {
    local request_dir=$1
    ka_profile_init_defaults
    mkdir -p "$request_dir/messages"
    ka_write_scalar "$request_dir/main_interval" "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval" 1500)"
    ka_write_scalar "$request_dir/secondary_enabled" "$(ka_read_first_line "$KA_PROFILE_DIR/secondary_enabled" 0)"
    ka_write_scalar "$request_dir/secondary_interval" "$(ka_read_first_line "$KA_PROFILE_DIR/secondary_interval" 600)"
    cp -f -- "$KA_PROFILE_DIR/secondary_message" "$request_dir/secondary_message"
    ka_write_scalar "$request_dir/notifications" "$(ka_read_first_line "$KA_PROFILE_DIR/notifications" 0)"
    ka_write_scalar "$request_dir/delivery_mode" "$(ka_read_first_line "$KA_PROFILE_DIR/delivery_mode" MESSAGE_ENTER)"
    rm -rf -- "$request_dir/messages"
    mkdir -p "$request_dir/messages"
    cp -f -- "$KA_PROFILE_DIR/messages"/[0-9][0-9][0-9] "$request_dir/messages/" 2>/dev/null || true
}

# Role: Replace the single persistent profile with validated values from one request.
ka_profile_update_from_request() {
    local request_dir=$1
    ka_profile_validate_request "$request_dir" || return
    ka_ensure_config_dirs

    ka_write_scalar "$KA_PROFILE_DIR/main_interval" "$(ka_read_first_line "$request_dir/main_interval")"
    ka_write_scalar "$KA_PROFILE_DIR/secondary_enabled" "$(ka_read_first_line "$request_dir/secondary_enabled")"
    ka_write_scalar "$KA_PROFILE_DIR/secondary_interval" "$(ka_read_first_line "$request_dir/secondary_interval")"
    cp -f -- "$request_dir/secondary_message" "$KA_PROFILE_DIR/secondary_message"
    chmod 600 "$KA_PROFILE_DIR/secondary_message" 2>/dev/null || true
    ka_write_scalar "$KA_PROFILE_DIR/notifications" "$(ka_read_first_line "$request_dir/notifications")"
    ka_write_scalar "$KA_PROFILE_DIR/delivery_mode" "$(ka_read_first_line "$request_dir/delivery_mode")"

    rm -rf -- "$KA_PROFILE_DIR/messages"
    mkdir -p "$KA_PROFILE_DIR/messages"
    chmod 700 "$KA_PROFILE_DIR/messages" 2>/dev/null || true
    cp -f -- "$request_dir/messages"/[0-9][0-9][0-9] "$KA_PROFILE_DIR/messages/"
}

# Role: Validate that main messages form a non-empty contiguous 001..N rotation.
ka_profile_validate_main_messages() {
    local messages_dir=$1
    (
        shopt -s nullglob
        local -a files=("$messages_dir"/[0-9][0-9][0-9])
        local file content expected index count

        [[ -d $messages_dir && ! -L $messages_dir ]] || {
            ka_error 'main messages path must be a regular directory'
            return 1
        }
        count=${#files[@]}

        ((count > 0)) || {
            ka_error 'at least one non-empty main message is required'
            return 1
        }

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
            content=$(cat -- "$file") || {
                ka_error "main message $expected could not be read"
                return 1
            }
            [[ -n $content && $content != *$'\n'* ]] || {
                ka_error "main message $expected must be one non-empty logical line"
                return 1
            }
        done
    )
}

# Role: Validate configuration files supplied by a TUI create/configure request.
ka_profile_validate_request() {
    local request_dir=$1
    local main_interval secondary_enabled secondary_interval notifications delivery_mode
    main_interval=$(ka_read_first_line "$request_dir/main_interval")
    secondary_enabled=$(ka_read_first_line "$request_dir/secondary_enabled")
    secondary_interval=$(ka_read_first_line "$request_dir/secondary_interval")
    notifications=$(ka_read_first_line "$request_dir/notifications")
    delivery_mode=$(ka_read_first_line "$request_dir/delivery_mode")

    ka_is_positive_int "$main_interval" || { ka_error 'main interval must be a positive number of seconds'; return 1; }
    [[ $secondary_enabled == 0 || $secondary_enabled == 1 ]] || { ka_error 'secondary_enabled must be 0 or 1'; return 1; }
    ka_is_positive_int "$secondary_interval" || { ka_error 'secondary interval must be a positive number of seconds'; return 1; }
    [[ $notifications == 0 || $notifications == 1 ]] || { ka_error 'notifications must be 0 or 1'; return 1; }
    [[ $delivery_mode == MESSAGE_ENTER || $delivery_mode == ENTER_ONLY ]] || { ka_error 'invalid delivery mode'; return 1; }
    [[ -f $request_dir/secondary_message ]] || { ka_error 'secondary message is missing'; return 1; }
    local secondary_content
    secondary_content=$(cat "$request_dir/secondary_message")
    if [[ $secondary_enabled == 1 ]]; then
        [[ -n $secondary_content ]] || { ka_error 'enabled secondary message cannot be empty'; return 1; }
        [[ $secondary_content != *$'\n'* ]] || { ka_error 'secondary message must be one logical line'; return 1; }
    fi

    ka_profile_validate_main_messages "$request_dir/messages"
}

# Role: Print the persistent profile in human-readable maintenance form.
ka_profile_print() {
    ka_profile_init_defaults
    printf 'main_interval=%s\n' "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")"
    printf 'secondary_enabled=%s\n' "$(ka_read_first_line "$KA_PROFILE_DIR/secondary_enabled")"
    printf 'secondary_interval=%s\n' "$(ka_read_first_line "$KA_PROFILE_DIR/secondary_interval")"
    printf 'secondary_message=%s\n' "$(ka_read_first_line "$KA_PROFILE_DIR/secondary_message")"
    printf 'notifications=%s\n' "$(ka_read_first_line "$KA_PROFILE_DIR/notifications")"
    printf 'delivery_mode=%s\n' "$(ka_read_first_line "$KA_PROFILE_DIR/delivery_mode")"
    printf 'messages:\n'
    local file
    for file in "$KA_PROFILE_DIR/messages"/[0-9][0-9][0-9]; do
        [[ -r $file ]] || continue
        printf '  - %s\n' "$(ka_read_first_line "$file")"
    done
}
