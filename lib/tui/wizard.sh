#!/usr/bin/env bash
# Guided create/configure wizard used for both AVAILABLE and existing targets.

# Role: Load wizard message files into the global KA_WIZ_MESSAGES indexed array.
ka_wizard_messages_load() {
    local config_dir=$1 file
    KA_WIZ_MESSAGES=()
    shopt -s nullglob
    for file in "$config_dir/messages"/[0-9][0-9][0-9]; do
        [[ -r $file ]] || continue
        KA_WIZ_MESSAGES+=("$(cat "$file")")
    done
    shopt -u nullglob
    ((${#KA_WIZ_MESSAGES[@]} > 0)) || KA_WIZ_MESSAGES=('ping')
}

# Role: Rewrite numbered message files from the in-memory wizard message array.
ka_wizard_messages_save() {
    local config_dir=$1 i file
    rm -rf -- "$config_dir/messages"
    mkdir -p "$config_dir/messages"
    for i in "${!KA_WIZ_MESSAGES[@]}"; do
        printf -v file '%s/messages/%03d' "$config_dir" "$((i + 1))"
        ka_write_scalar "$file" "${KA_WIZ_MESSAGES[$i]}"
    done
}

# Role: Render and edit the ordered main-message rotation in wizard step one.
ka_wizard_step_messages() {
    local config_dir=$1 type=$2 name=$3 selected=0 key value i
    ka_wizard_messages_load "$config_dir"
    while true; do
        ((selected >= ${#KA_WIZ_MESSAGES[@]})) && selected=$((${#KA_WIZ_MESSAGES[@]} - 1))
        ((selected < 0)) && selected=0
        ka_tui_frame_begin
        printf '╭─ %s Create/Configure Keep Alive ─ %s / %s ─╮\n' "$KA_I_MESSAGE" "$type" "$name"
        printf '│ Step 1 of 6 · Main message rotation\n│\n'
        for i in "${!KA_WIZ_MESSAGES[@]}"; do
            if ((i == selected)); then printf '│  %s❯ %d  %s%s\n' "$KA_BOLD" "$((i + 1))" "${KA_WIZ_MESSAGES[$i]}" "$KA_RESET"
            else printf '│    %d  %s\n' "$((i + 1))" "${KA_WIZ_MESSAGES[$i]}"; fi
        done
        printf '│\n│  a add    e edit    x remove    ↑/↓ select    Enter continue    Esc cancel\n'
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in
            UP|k) ((selected > 0)) && selected=$((selected - 1)) ;;
            DOWN|j) ((selected + 1 < ${#KA_WIZ_MESSAGES[@]})) && selected=$((selected + 1)) ;;
            a|A)
                value=$(ka_tui_prompt_line 'New message')
                [[ -n $value ]] && KA_WIZ_MESSAGES+=("$value")
                selected=$((${#KA_WIZ_MESSAGES[@]} - 1))
                ;;
            e|E)
                value=$(ka_tui_prompt_line 'Edit message' "${KA_WIZ_MESSAGES[$selected]}")
                [[ -n $value ]] && KA_WIZ_MESSAGES[$selected]=$value
                ;;
            x|X)
                if ((${#KA_WIZ_MESSAGES[@]} > 1)); then
                    unset 'KA_WIZ_MESSAGES[selected]'
                    KA_WIZ_MESSAGES=("${KA_WIZ_MESSAGES[@]}")
                else
                    ka_tui_toast 'At least one main message is required.'
                fi
                ;;
            ENTER)
                ka_wizard_messages_save "$config_dir"
                return 0
                ;;
            ESC) return 1 ;;
        esac
    done
}

# Role: Guide selection of the main timer interval with presets and a custom minute value.
ka_wizard_step_main_interval() {
    local config_dir=$1 current selected=0 key value
    current=$(ka_read_first_line "$config_dir/main_interval" 1500)
    case $current in 1500) selected=0;; 900) selected=1;; 300) selected=2;; *) selected=3;; esac
    while true; do
        ka_tui_frame_begin
        printf '╭─ %s Create/Configure Keep Alive · Step 2 of 6 ─╮\n' "$KA_I_TIMER"
        printf '│ Main interval\n│\n'
        local -a labels=('25 minutes (recommended)' '15 minutes' '5 minutes' 'custom')
        local i
        for i in 0 1 2 3; do
            if ((i == selected)); then printf '│  %s❯ %d  %s%s\n' "$KA_BOLD" "$((i + 1))" "${labels[$i]}" "$KA_RESET"
            else printf '│    %d  %s\n' "$((i + 1))" "${labels[$i]}"; fi
        done
        printf '│\n│  ↑/↓ select    1–4 direct    Enter continue    Esc back\n'
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in
            UP|k) ((selected > 0)) && selected=$((selected - 1)) ;;
            DOWN|j) ((selected < 3)) && selected=$((selected + 1)) ;;
            [1-4]) selected=$((key - 1)) ;;
            ENTER)
                case $selected in
                    0) value=1500 ;;
                    1) value=900 ;;
                    2) value=300 ;;
                    3)
                        value=$(ka_tui_prompt_line 'Custom interval in minutes' "$((current / 60))")
                        ka_is_positive_int "$value" || { ka_tui_toast 'Enter a positive whole number of minutes.'; continue; }
                        value=$((value * 60))
                        ;;
                esac
                ka_write_scalar "$config_dir/main_interval" "$value"
                return 0
                ;;
            ESC) return 2 ;;
        esac
    done
}

# Role: Configure optional secondary prompt text and interval in one guided step.
ka_wizard_step_secondary() {
    local config_dir=$1 enabled interval message key value choice=0
    enabled=$(ka_read_first_line "$config_dir/secondary_enabled" 0)
    interval=$(ka_read_first_line "$config_dir/secondary_interval" 600)
    message=$(cat "$config_dir/secondary_message" 2>/dev/null || true)
    [[ $enabled == 1 ]] && choice=1
    while true; do
        ka_tui_frame_begin
        printf '╭─ %s Create/Configure Keep Alive · Step 3 of 6 ─╮\n' "$KA_I_SECONDARY"
        printf '│ Secondary prompt\n│\n'
        printf '│   %s Disabled%s\n' "$([[ $choice == 0 ]] && printf '%s❯ ' "$KA_BOLD" || printf '  ')" "$KA_RESET"
        printf '│   %s Enabled%s\n' "$([[ $choice == 1 ]] && printf '%s❯ ' "$KA_BOLD" || printf '  ')" "$KA_RESET"
        if ((choice == 1)); then
            printf '│\n│ Message : %s\n' "$message"
            printf '│ Interval: %s\n' "$(ka_format_duration "$interval")"
        fi
        printf '│\n│  ↑/↓ toggle    Enter continue    Esc back\n'
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in
            UP|DOWN|j|k) choice=$((1 - choice)) ;;
            ENTER)
                if ((choice == 1)); then
                    value=$(ka_tui_prompt_line 'Secondary message' "${message:-Continue if there is unfinished work.}")
                    [[ -n $value ]] || continue
                    message=$value
                    value=$(ka_tui_prompt_line 'Secondary interval in minutes' "$((interval / 60))")
                    ka_is_positive_int "$value" || { ka_tui_toast 'Enter a positive whole number of minutes.'; continue; }
                    interval=$((value * 60))
                fi
                ka_write_scalar "$config_dir/secondary_enabled" "$choice"
                ka_write_scalar "$config_dir/secondary_interval" "$interval"
                printf '%s' "$message" | ka_atomic_write "$config_dir/secondary_message"
                return 0
                ;;
            ESC) return 2 ;;
        esac
    done
}

# Role: Configure the per-target desktop notification toggle.
ka_wizard_step_notifications() {
    local config_dir=$1 current choice key
    current=$(ka_read_first_line "$config_dir/notifications" 0)
    choice=$current
    while true; do
        ka_tui_frame_begin
        printf '╭─ %s Create/Configure Keep Alive · Step 4 of 6 ─╮\n' "$KA_I_NOTIFY"
        printf '│ Desktop notifications\n│\n'
        printf '│   %s OFF%s\n' "$([[ $choice == 0 ]] && printf '%s❯ ' "$KA_BOLD" || printf '  ')" "$KA_RESET"
        printf '│   %s ON%s\n' "$([[ $choice == 1 ]] && printf '%s❯ ' "$KA_BOLD" || printf '  ')" "$KA_RESET"
        printf '│\n│ Successful sends and target-loss events follow this setting.\n'
        printf '│\n│  ↑/↓ toggle    Enter continue    Esc back\n'
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in
            UP|DOWN|j|k) choice=$((1 - choice)) ;;
            ENTER) ka_write_scalar "$config_dir/notifications" "$choice"; return 0 ;;
            ESC) return 2 ;;
        esac
    done
}

# Role: Configure the whole-target MESSAGE+ENTER versus ENTER_ONLY delivery behavior.
ka_wizard_step_delivery() {
    local config_dir=$1 current choice key
    current=$(ka_read_first_line "$config_dir/delivery_mode" MESSAGE_ENTER)
    [[ $current == ENTER_ONLY ]] && choice=1 || choice=0
    while true; do
        ka_tui_frame_begin
        printf '╭─ %s Create/Configure Keep Alive · Step 5 of 6 ─╮\n' "$KA_I_ENTER"
        printf '│ Delivery mode\n│\n'
        printf '│   %s MESSAGE + ENTER%s\n' "$([[ $choice == 0 ]] && printf '%s❯ ' "$KA_BOLD" || printf '  ')" "$KA_RESET"
        printf '│   %s ENTER ONLY%s\n' "$([[ $choice == 1 ]] && printf '%s❯ ' "$KA_BOLD" || printf '  ')" "$KA_RESET"
        printf '│\n│ Pressing e later toggles this mode for the selected target.\n'
        printf '│\n│  ↑/↓ toggle    Enter continue    Esc back\n'
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in
            UP|DOWN|j|k) choice=$((1 - choice)) ;;
            ENTER)
                [[ $choice == 1 ]] && ka_write_scalar "$config_dir/delivery_mode" ENTER_ONLY || ka_write_scalar "$config_dir/delivery_mode" MESSAGE_ENTER
                return 0
                ;;
            ESC) return 2 ;;
        esac
    done
}

# Role: Review all wizard values and obtain final explicit save confirmation.
ka_wizard_step_review() {
    local config_dir=$1 type=$2 name=$3 key count=0 file secondary
    shopt -s nullglob
    for file in "$config_dir/messages"/[0-9][0-9][0-9]; do ((count += 1)); done
    shopt -u nullglob
    secondary=$(ka_read_first_line "$config_dir/secondary_enabled" 0)
    while true; do
        ka_tui_frame_begin
        printf '╭─ %s Create/Configure Keep Alive · Step 6 of 6 ─╮\n' "$KA_I_CONFIG"
        printf '│ Review · %s / %s\n│\n' "$type" "$name"
        printf '│ Main messages      %d-message rotation\n' "$count"
        printf '│ Main interval      %s\n' "$(ka_format_duration "$(ka_read_first_line "$config_dir/main_interval")")"
        if [[ $secondary == 1 ]]; then
            printf '│ Secondary          %s · %s\n' "$(ka_format_duration "$(ka_read_first_line "$config_dir/secondary_interval")")" "$(ka_read_first_line "$config_dir/secondary_message")"
        else
            printf '│ Secondary          disabled\n'
        fi
        printf '│ Notifications      %s\n' "$([[ $(ka_read_first_line "$config_dir/notifications") == 1 ]] && printf ON || printf OFF)"
        printf '│ Delivery           %s\n' "$(ka_read_first_line "$config_dir/delivery_mode")"
        printf '│\n│ Saving updates this target and the one global profile only.\n'
        printf '│ Existing keep-alives are not changed.\n'
        printf '│\n│  Enter save      Esc back\n'
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in ENTER) return 0;; ESC) return 2;; esac
    done
}

# Role: Run the six-step guided wizard and submit CREATE/CONFIGURE atomically to the daemon.
ka_tui_run_wizard() {
    local uuid=$1 status=$2 type=$3 name=$4 tmp step=1 rc id req response command
    tmp=$(mktemp -d "$KA_RUNTIME_DIR/wizard.XXXXXX") || return 1
    mkdir -p "$tmp/config"
    if [[ $status == AVAILABLE ]]; then
        ka_profile_copy_to_request "$tmp/config"
        command=CREATE
    else
        ka_state_copy_target_to_request "$uuid" "$tmp/config" || { rm -rf "$tmp"; return 1; }
        command=CONFIGURE
    fi

    while ((step >= 1 && step <= 6)); do
        case $step in
            1) ka_wizard_step_messages "$tmp/config" "$type" "$name"; rc=$? ;;
            2) ka_wizard_step_main_interval "$tmp/config"; rc=$? ;;
            3) ka_wizard_step_secondary "$tmp/config"; rc=$? ;;
            4) ka_wizard_step_notifications "$tmp/config"; rc=$? ;;
            5) ka_wizard_step_delivery "$tmp/config"; rc=$? ;;
            6) ka_wizard_step_review "$tmp/config" "$type" "$name"; rc=$? ;;
        esac
        if ((rc == 0)); then step=$((step + 1))
        elif ((rc == 2)); then step=$((step - 1)); ((step < 1)) && { rm -rf "$tmp"; return 1; }
        else rm -rf "$tmp"; return 1
        fi
    done

    id=$(ka_ipc_new_request "$command" "$uuid") || { rm -rf "$tmp"; return 1; }
    req=$(ka_ipc_request_dir "$id")
    cp -a -- "$tmp/config" "$req/config"
    rm -rf -- "$tmp"
    if ! ka_ipc_signal_request "$id"; then
        rm -rf -- "$req"
        return 1
    fi
    response=$(ka_ipc_wait_response "$id")
    if [[ $response == OK$'\t'* ]]; then
        ka_tui_toast "$([[ $command == CREATE ]] && printf 'Keep-alive created.' || printf 'Configuration saved; timers reset.')"
        return 0
    fi
    ka_tui_toast "${response#*$'\t'}"
    return 1
}
