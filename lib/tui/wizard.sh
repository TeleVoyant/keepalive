#!/usr/bin/env bash
# Guided create/configure wizard used for both AVAILABLE and existing targets.

# Role: Remove wizard scratch directories abandoned by a previously killed TUI client.
# The EXIT trap covers normal exits and Ctrl-C; only SIGKILL can still orphan one.
# The threshold stays generous because another client may have a wizard open right now.
ka_wizard_cleanup_stale() {
    command -v find >/dev/null 2>&1 || return 0
    find "$KA_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d -name 'wizard.*' -mmin +240 \
        -exec rm -rf -- {} + 2>/dev/null || true
}

# Role: Render a six-step progress indicator with completed, current, and pending marks.
ka_wizard_progress() {
    local step=$1 i out=''
    for i in 1 2 3 4 5 6; do
        if ((i < step)); then out+="${KA_GREEN}${KA_G_DOT_ON}${KA_RESET}"
        elif ((i == step)); then out+="${KA_CYAN}${KA_BOLD}${KA_G_DOT_ON}${KA_RESET}"
        else out+="${KA_DIM}${KA_G_DOT_OFF}${KA_RESET}"
        fi
        ((i < 6)) && out+=' '
    done
    printf '%s' "$out"
}

# Role: Render the shared wizard header, as a colored segment bar where the terminal
# allows it and as the plain box otherwise.
# Mirrors the manager and detail headers so every screen shares one visual language,
# while --no-color, NO_COLOR, and a too-narrow terminal still get a complete header.
ka_wizard_header() {
    local icon=$1 step=$2 title=$3 subject=${KA_WIZARD_SUBJECT-} width
    width=$(ka_tui_field_width 46 10)
    if ka_tui_bar_supported; then
        ka_tui_bar_begin
        ka_tui_bar_add 4 7 "$(ka_icon_label "$icon" "${KA_WIZARD_ACTION:-Configure}")" 1
        ka_tui_bar_add 5 7 "step $step/6"
        ka_tui_bar_add 0 7 "$title"
        [[ -n $subject ]] && ka_tui_bar_add 6 0 "$(ka_tui_truncate "$subject" "$width")"
        ka_tui_bar_end
        if ka_tui_bar_flush; then
            printf '%s  %s\033[K\n%s\033[K\n' "$KA_G_V" "$(ka_wizard_progress "$step")" "$KA_G_V"
            return 0
        fi
    fi
    ka_tui_box_top "$icon" "${KA_WIZARD_ACTION:-Configure} Keep Alive - Step $step of 6"
    if [[ -n $subject ]]; then
        printf '%s %s  %s%s%s\033[K\n' "$KA_G_V" "$title" "$KA_DIM" "$(ka_tui_truncate "$subject" "$width")" "$KA_RESET"
    else
        printf '%s %s\033[K\n' "$KA_G_V" "$title"
    fi
    printf '%s  %s\033[K\n%s\033[K\n' "$KA_G_V" "$(ka_wizard_progress "$step")" "$KA_G_V"
}

# Role: Draw the key-hint footer, choosing a compact form on narrow terminals.
# These were fixed-width literals; step one's was 80 columns and wrapped on anything
# smaller, which is the same defect already fixed in the manager and detail footers.
ka_wizard_hint() {
    local long=$1 short=${2-} text
    text=$long
    [[ -n $short ]] && ((${KA_TUI_COLS:-80} < ${#long} + 4)) && text=$short
    printf '%s\033[K\n%s  %s\033[K\n' "$KA_G_V" "$KA_G_V" "$(ka_tui_truncate "$text" "$(ka_tui_field_width 4)")"
}

# Role: Draw a selectable wizard option line with a consistent highlight marker.
ka_wizard_option() {
    local active=$1 number=$2 label=$3 width
    width=$(ka_tui_field_width 12 10)
    label=$(ka_tui_truncate "$label" "$width")
    if [[ $active == 1 ]]; then
        printf '%s  %s%s%s %s%s  %s%s\033[K\n' "$KA_G_V" "$KA_CYAN" "$KA_BOLD" "$KA_G_SEL" \
            "$number" "$KA_RESET" "${KA_BOLD}${label}" "$KA_RESET"
    else
        printf '%s    %s%s%s  %s\033[K\n' "$KA_G_V" "$KA_DIM" "$number" "$KA_RESET" "$label"
    fi
}

# Role: Report whether the terminal is too small for a wizard step and draw the notice.
ka_wizard_too_small() {
    ka_tui_too_small 52 14 || return 1
    ka_tui_render_too_small 52 14
    ka_tui_frame_end
    return 0
}

# Role: Load wizard message files into the global KA_WIZ_MESSAGES indexed array.
ka_wizard_messages_load() {
    local config_dir=$1 file had_nullglob=0
    KA_WIZ_MESSAGES=()
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
    for file in "$config_dir/messages"/[0-9][0-9][0-9]; do
        [[ -r $file ]] || continue
        KA_WIZ_MESSAGES+=("$(cat -- "$file")")
    done
    ((had_nullglob == 1)) || shopt -u nullglob
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
    local config_dir=$1 type=$2 name=$3 selected=0 key value i text_w
    ka_wizard_messages_load "$config_dir"
    while true; do
        ((selected >= ${#KA_WIZ_MESSAGES[@]})) && selected=$((${#KA_WIZ_MESSAGES[@]} - 1))
        ((selected < 0)) && selected=0
        ka_tui_frame_begin
        if ka_wizard_too_small; then ka_tui_read_key 60 || continue; [[ $KA_KEY == ESC ]] && return 1; continue; fi
        text_w=$(ka_tui_field_width 12 12)
        ka_wizard_header "$KA_I_MESSAGE" 1 'Main message rotation'
        for i in "${!KA_WIZ_MESSAGES[@]}"; do
            ka_wizard_option "$((i == selected))" "$((i + 1))" "$(ka_tui_truncate "${KA_WIZ_MESSAGES[$i]}" "$text_w")"
        done
        ka_wizard_hint 'a add    e edit    x remove    up/down select    Enter continue    Esc cancel' \
            'a add  e edit  x remove  Enter next  Esc cancel'
        ka_tui_box_bottom
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in
            UP|k) ((selected > 0)) && selected=$((selected - 1)) ;;
            DOWN|j) ((selected + 1 < ${#KA_WIZ_MESSAGES[@]})) && selected=$((selected + 1)) ;;
            a|A)
                ka_tui_prompt_line 'New message'; value=$KA_PROMPT_VALUE
                [[ -n $value ]] && KA_WIZ_MESSAGES+=("$value")
                selected=$((${#KA_WIZ_MESSAGES[@]} - 1))
                ;;
            e|E)
                ka_tui_prompt_line 'Edit message' "${KA_WIZ_MESSAGES[$selected]}"; value=$KA_PROMPT_VALUE
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
    local -a labels=('25 minutes (recommended)' '15 minutes' '5 minutes' 'custom')
    while true; do
        ka_tui_frame_begin
        if ka_wizard_too_small; then ka_tui_read_key 60 || continue; [[ $KA_KEY == ESC ]] && return 2; continue; fi
        ka_wizard_header "$KA_I_TIMER" 2 'Main interval'
        local i
        for i in 0 1 2 3; do
            ka_wizard_option "$((i == selected))" "$((i + 1))" "${labels[$i]}"
        done
        ka_wizard_hint 'up/down select    1-4 direct    Enter continue    Esc back' \
            'up/down  1-4  Enter next  Esc back'
        ka_tui_box_bottom
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
                        ka_tui_prompt_line 'Custom interval in minutes' "$((current / 60))"; value=$KA_PROMPT_VALUE
                        # Bounded before scaling: the seconds must stay a valid interval.
                        { ka_is_interval "$value" && ka_is_interval "$((value * 60))"; } \
                            || { ka_tui_toast 'Enter a whole number of minutes from 1 to 16666666.'; continue; }
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
    local config_dir=$1 enabled interval message key value choice=0 text_w
    enabled=$(ka_read_first_line "$config_dir/secondary_enabled" 0)
    interval=$(ka_read_first_line "$config_dir/secondary_interval" 600)
    message=$(cat "$config_dir/secondary_message" 2>/dev/null || true)
    [[ $enabled == 1 ]] && choice=1
    while true; do
        ka_tui_frame_begin
        if ka_wizard_too_small; then ka_tui_read_key 60 || continue; [[ $KA_KEY == ESC ]] && return 2; continue; fi
        text_w=$(ka_tui_field_width 14 12)
        ka_wizard_header "$KA_I_SECONDARY" 3 'Secondary prompt'
        ka_wizard_option "$((choice == 0))" '1' 'Disabled'
        ka_wizard_option "$((choice == 1))" '2' 'Enabled'
        if ((choice == 1)); then
            printf '%s\033[K\n%s Message : %s\033[K\n' "$KA_G_V" "$KA_G_V" "$(ka_tui_truncate "$message" "$text_w")"
            printf '%s Interval: %s\033[K\n' "$KA_G_V" "$(ka_format_duration "$interval")"
        fi
        ka_wizard_hint 'up/down toggle    Enter continue    Esc back' 'up/down  Enter next  Esc back'
        ka_tui_box_bottom
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in
            UP|DOWN|j|k) choice=$((1 - choice)) ;;
            1) choice=0 ;;
            2) choice=1 ;;
            ENTER)
                if ((choice == 1)); then
                    ka_tui_prompt_line 'Secondary message' "${message:-Continue if there is unfinished work.}"; value=$KA_PROMPT_VALUE
                    [[ -n $value ]] || continue
                    message=$value
                    ka_tui_prompt_line 'Secondary interval in minutes' "$((interval / 60))"; value=$KA_PROMPT_VALUE
                    { ka_is_interval "$value" && ka_is_interval "$((value * 60))"; } \
                        || { ka_tui_toast 'Enter a whole number of minutes from 1 to 16666666.'; continue; }
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
    local config_dir=$1 choice key
    choice=$(ka_read_first_line "$config_dir/notifications" 0)
    while true; do
        ka_tui_frame_begin
        if ka_wizard_too_small; then ka_tui_read_key 60 || continue; [[ $KA_KEY == ESC ]] && return 2; continue; fi
        ka_wizard_header "$KA_I_NOTIFY" 4 'Desktop notifications'
        ka_wizard_option "$((choice == 0))" '1' 'OFF'
        ka_wizard_option "$((choice == 1))" '2' 'ON'
        printf '%s\033[K\n%s Successful sends and target-loss events follow this setting.\033[K\n' "$KA_G_V" "$KA_G_V"
        ka_wizard_hint 'up/down toggle    Enter continue    Esc back' 'up/down  Enter next  Esc back'
        ka_tui_box_bottom
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in
            UP|DOWN|j|k) choice=$((1 - choice)) ;;
            1) choice=0 ;;
            2) choice=1 ;;
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
        if ka_wizard_too_small; then ka_tui_read_key 60 || continue; [[ $KA_KEY == ESC ]] && return 2; continue; fi
        ka_wizard_header "$KA_I_ENTER" 5 'Delivery mode'
        ka_wizard_option "$((choice == 0))" '1' 'MESSAGE + ENTER'
        ka_wizard_option "$((choice == 1))" '2' 'ENTER ONLY'
        printf '%s\033[K\n%s Pressing e later sends one Enter; E switches to ENTER ONLY.\033[K\n' "$KA_G_V" "$KA_G_V"
        ka_wizard_hint 'up/down toggle    Enter continue    Esc back' 'up/down  Enter next  Esc back'
        ka_tui_box_bottom
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in
            UP|DOWN|j|k) choice=$((1 - choice)) ;;
            1) choice=0 ;;
            2) choice=1 ;;
            ENTER)
                # An if/else, not `A && B || C`: a failed ENTER_ONLY write would otherwise
                # fall through and store MESSAGE_ENTER, silently choosing the other mode.
                if [[ $choice == 1 ]]; then
                    ka_write_scalar "$config_dir/delivery_mode" ENTER_ONLY
                else
                    ka_write_scalar "$config_dir/delivery_mode" MESSAGE_ENTER
                fi
                return 0
                ;;
            ESC) return 2 ;;
        esac
    done
}

# Role: Review all wizard values and obtain final explicit save confirmation.
ka_wizard_step_review() {
    local config_dir=$1 type=$2 name=$3 key count=0 file secondary text_w had_nullglob=0
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
    for file in "$config_dir/messages"/[0-9][0-9][0-9]; do ((count += 1)); done
    ((had_nullglob == 1)) || shopt -u nullglob
    secondary=$(ka_read_first_line "$config_dir/secondary_enabled" 0)
    while true; do
        ka_tui_frame_begin
        if ka_wizard_too_small; then ka_tui_read_key 60 || continue; [[ $KA_KEY == ESC ]] && return 2; continue; fi
        text_w=$(ka_tui_field_width 24 12)
        ka_wizard_header "$KA_I_CONFIG" 6 'Review and save'
        printf '%s Main messages      %d-message rotation\033[K\n' "$KA_G_V" "$count"
        printf '%s Main interval      %s\033[K\n' "$KA_G_V" "$(ka_format_duration "$(ka_read_first_line "$config_dir/main_interval")")"
        if [[ $secondary == 1 ]]; then
            printf '%s Secondary          %s - %s\033[K\n' "$KA_G_V" \
                "$(ka_format_duration "$(ka_read_first_line "$config_dir/secondary_interval")")" \
                "$(ka_tui_truncate "$(ka_read_first_line "$config_dir/secondary_message")" "$text_w")"
        else
            printf '%s Secondary          disabled\033[K\n' "$KA_G_V"
        fi
        printf '%s Notifications      %s\033[K\n' "$KA_G_V" "$([[ $(ka_read_first_line "$config_dir/notifications") == 1 ]] && printf ON || printf OFF)"
        printf '%s Delivery           %s\033[K\n' "$KA_G_V" "$(ka_read_first_line "$config_dir/delivery_mode")"
        printf '%s\033[K\n%s Saving updates this target and the one global profile only.\033[K\n' "$KA_G_V" "$KA_G_V"
        printf '%s Existing keep-alives are not changed.\033[K\n' "$KA_G_V"
        ka_wizard_hint 'Enter save      Esc back'
        ka_tui_box_bottom
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in ENTER) return 0;; ESC) return 2;; esac
    done
}

# Role: Run the six-step guided wizard and submit CREATE/CONFIGURE atomically to the daemon.
ka_tui_run_wizard() {
    local uuid=$1 status=$2 type=$3 name=$4 tmp step=1 rc id req response command
    KA_WIZARD_SUBJECT="$type / $name"
    [[ $status == AVAILABLE ]] && KA_WIZARD_ACTION=Create || KA_WIZARD_ACTION=Configure
    tmp=$(mktemp -d "$KA_RUNTIME_DIR/wizard.XXXXXX") || return 1
    # Publish the scratch path so ka_tui_leave removes it on Ctrl-C, SIGTERM, or exit.
    KA_TUI_SCRATCH=$tmp
    mkdir -p "$tmp/config"
    if [[ $status == AVAILABLE ]]; then
        ka_profile_copy_to_request "$tmp/config"
        command=CREATE
    else
        ka_state_copy_target_to_request "$uuid" "$tmp/config" || { ka_wizard_discard "$tmp"; return 1; }
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
        elif ((rc == 2)); then step=$((step - 1)); ((step < 1)) && { ka_wizard_discard "$tmp"; return 1; }
        else ka_wizard_discard "$tmp"; return 1
        fi
    done

    ka_ipc_new_request "$command" "$uuid" >/dev/null \
        || { ka_wizard_discard "$tmp"; return 1; }
    id=$KA_IPC_REQUEST_ID
    req=$(ka_ipc_request_dir "$id")
    cp -a -- "$tmp/config" "$req/config"
    ka_wizard_discard "$tmp"
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

# Role: Remove one wizard scratch directory and clear the exit-time cleanup handle.
ka_wizard_discard() {
    local tmp=$1
    rm -rf -- "$tmp"
    [[ ${KA_TUI_SCRATCH:-} == "$tmp" ]] && KA_TUI_SCRATCH=''
    return 0
}
