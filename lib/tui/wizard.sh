#!/usr/bin/env bash
# Settings editor used to create AVAILABLE targets and reconfigure existing ones.
#
# One screen lists every setting with the target's live countdowns; any field can be picked
# and changed in any order, and nothing reaches the daemon until the user saves. The field
# screens below are its sub-editors: each edits the scratch copy of the configuration and
# returns to the list. The daemon keeps counting while the editor is open, and saving keeps
# the countdowns running (see ka_state_apply_request_configuration).

# The editable fields in display order; their positions are the direct-select digits.
KA_WIZARD_FIELDS=(messages main secondary notifications delivery profile)
KA_WIZARD_LABELS=('Messages' 'Main interval' 'Secondary prompt' 'Notifications' 'Delivery'
    'Save as default')
declare -ga KA_WIZ_WAS_TEXT=() KA_WIZ_WAS_SIG=() KA_WIZ_NOW_TEXT=() KA_WIZ_NOW_SIG=()
declare -ga KA_WIZ_EFFECTS=()
KA_WIZ_DIR='' KA_WIZ_ORIGINAL='' KA_WIZ_LOADED_AT=0 KA_WIZ_LAST_DRAW=0 KA_WIZ_AWAY=0
KA_WIZ_BASE_MAIN=0 KA_WIZ_BASE_SEC=0 KA_WIZ_MAIN_LEFT=0 KA_WIZ_SEC_LEFT=0

# Role: Remove editor scratch directories abandoned by a previously killed TUI client.
# The EXIT trap covers normal exits and Ctrl-C; only SIGKILL can still orphan one.
# The threshold stays generous because another client may have an editor open right now.
ka_wizard_cleanup_stale() {
    command -v find >/dev/null 2>&1 || return 0
    find "$KA_RUNTIME_DIR" -mindepth 1 -maxdepth 1 -type d -name 'wizard.*' -mmin +240 \
        -exec rm -rf -- {} + 2>/dev/null || true
}

# Role: Render the shared editor header, as a colored segment bar where the terminal
# allows it and as the plain box otherwise.
# Mirrors the manager and detail headers so every screen shares one visual language,
# while --no-color, NO_COLOR, and a too-narrow terminal still get a complete header.
ka_wizard_header() {
    local icon=$1 title=$2 subject=${KA_WIZARD_SUBJECT-} width
    ka_tui_field_width_set 46 10; width=$REPLY
    if ka_tui_bar_supported; then
        ka_tui_bar_begin
        ka_icon_label_set "$icon" "${KA_WIZARD_ACTION:-Configure}"
        ka_tui_bar_add 4 7 "$REPLY" 1
        ka_tui_bar_add 0 7 "$title"
        if [[ -n $subject ]]; then
            ka_tui_truncate_set "$subject" "$width"
            ka_tui_bar_add 6 0 "$REPLY"
        fi
        ka_tui_bar_end
        if ka_tui_bar_flush; then
            printf '%s\033[K\n' "$KA_G_V"
            return 0
        fi
    fi
    ka_tui_box_top "$icon" "${KA_WIZARD_ACTION:-Configure} Keep Alive"
    if [[ -n $subject ]]; then
        ka_tui_truncate_set "$subject" "$width"
        printf '%s %s  %s%s%s\033[K\n' "$KA_G_V" "$title" "$KA_DIM" "$REPLY" "$KA_RESET"
    else
        printf '%s %s\033[K\n' "$KA_G_V" "$title"
    fi
    printf '%s\033[K\n' "$KA_G_V"
}

# Role: Draw the key-hint footer, choosing a compact form on narrow terminals.
# These were fixed-width literals; step one's was 80 columns and wrapped on anything
# smaller, which is the same defect already fixed in the manager and detail footers.
# REPLY helpers, not command substitutions: the settings list redraws this every second.
ka_wizard_hint() {
    local long=$1 short=${2-} text width
    text=$long
    [[ -n $short ]] && ((${KA_TUI_COLS:-80} < ${#long} + 4)) && text=$short
    ka_tui_field_width_set 4; width=$REPLY
    ka_tui_truncate_set "$text" "$width"
    printf '%s\033[K\n%s  %s\033[K\n' "$KA_G_V" "$KA_G_V" "$REPLY"
}

# Role: Draw a selectable option line with a consistent highlight marker.
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

# Role: Report whether the terminal is too small for an editor screen and draw the notice.
# The field screens fit in 14 lines; the settings list needs more (see its renderer).
ka_wizard_too_small() {
    local height=${1:-14}
    ka_tui_too_small 52 "$height" || return 1
    ka_tui_render_too_small 52 "$height"
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

# Role: Edit the ordered main-message rotation; Enter keeps the edits, Esc drops them.
ka_wizard_step_messages() {
    local config_dir=$1 type=$2 name=$3 selected=0 key value i text_w
    ka_wizard_messages_load "$config_dir"
    while true; do
        ((selected >= ${#KA_WIZ_MESSAGES[@]})) && selected=$((${#KA_WIZ_MESSAGES[@]} - 1))
        ((selected < 0)) && selected=0
        ka_tui_frame_begin
        if ka_wizard_too_small; then ka_tui_read_key 60 || continue; [[ $KA_KEY == ESC ]] && return 1; continue; fi
        text_w=$(ka_tui_field_width 12 12)
        ka_wizard_header "$KA_I_MESSAGE" 'Main message rotation'
        for i in "${!KA_WIZ_MESSAGES[@]}"; do
            ka_wizard_option "$((i == selected))" "$((i + 1))" "$(ka_tui_truncate "${KA_WIZ_MESSAGES[$i]}" "$text_w")"
        done
        ka_wizard_hint 'a add    e edit    x remove    up/down select    Enter done    Esc discard' \
            'a add  e edit  x remove  Enter done  Esc discard'
        ka_tui_box_bottom
        ka_tui_render_toast
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

# Role: Choose the main timer interval from presets or a custom minute value.
ka_wizard_step_main_interval() {
    local config_dir=$1 current selected=0 key value
    current=$(ka_read_first_line "$config_dir/main_interval" 1500)
    case $current in 1500) selected=0;; 900) selected=1;; 300) selected=2;; *) selected=3;; esac
    local -a labels=('25 minutes (recommended)' '15 minutes' '5 minutes' 'custom')
    while true; do
        ka_tui_frame_begin
        if ka_wizard_too_small; then ka_tui_read_key 60 || continue; [[ $KA_KEY == ESC ]] && return 2; continue; fi
        ka_wizard_header "$KA_I_TIMER" 'Main interval'
        local i
        for i in 0 1 2 3; do
            ka_wizard_option "$((i == selected))" "$((i + 1))" "${labels[$i]}"
        done
        ka_wizard_hint 'up/down select    1-4 direct    Enter choose    Esc back' \
            'up/down  1-4  Enter choose  Esc back'
        ka_tui_box_bottom
        ka_tui_render_toast
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

# Role: Configure optional secondary prompt text and interval in one screen.
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
        ka_wizard_header "$KA_I_SECONDARY" 'Secondary prompt'
        ka_wizard_option "$((choice == 0))" '1' 'Disabled'
        ka_wizard_option "$((choice == 1))" '2' 'Enabled'
        if ((choice == 1)); then
            printf '%s\033[K\n%s Message : %s\033[K\n' "$KA_G_V" "$KA_G_V" "$(ka_tui_truncate "$message" "$text_w")"
            printf '%s Interval: %s\033[K\n' "$KA_G_V" "$(ka_format_duration "$interval")"
        fi
        ka_wizard_hint 'up/down toggle    Enter choose    Esc back' 'up/down  Enter choose  Esc back'
        ka_tui_box_bottom
        ka_tui_render_toast
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
        ka_wizard_header "$KA_I_NOTIFY" 'Desktop notifications'
        ka_wizard_option "$((choice == 0))" '1' 'OFF'
        ka_wizard_option "$((choice == 1))" '2' 'ON'
        printf '%s\033[K\n%s Successful sends and target-loss events follow this setting.\033[K\n' "$KA_G_V" "$KA_G_V"
        ka_wizard_hint 'up/down toggle    Enter choose    Esc back' 'up/down  Enter choose  Esc back'
        ka_tui_box_bottom
        ka_tui_render_toast
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
        ka_wizard_header "$KA_I_ENTER" 'Delivery mode'
        ka_wizard_option "$((choice == 0))" '1' 'MESSAGE + ENTER'
        ka_wizard_option "$((choice == 1))" '2' 'ENTER ONLY'
        printf '%s\033[K\n%s Pressing e later sends one Enter; E switches to ENTER ONLY.\033[K\n' "$KA_G_V" "$KA_G_V"
        ka_wizard_hint 'up/down toggle    Enter choose    Esc back' 'up/down  Enter choose  Esc back'
        ka_tui_box_bottom
        ka_tui_render_toast
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

# Role: Read one small scratch-configuration file into REPLY without forking.
# Drops one final newline, as the daemon's scalar reader does, so a field rewritten with
# the same value compares equal; an absent or symlinked file reads as empty.
ka_wizard_read_set() {
    local path=$1
    REPLY=''
    [[ -f $path && ! -L $path ]] || return 0
    IFS= read -r -d '' REPLY <"$path" || true
    REPLY=${REPLY%$'\n'}
}

# Role: Describe one field of a configuration directory: display text into REPLY and its
# exact content into KA_WIZARD_SIGNATURE, which is what a change is detected from.
ka_wizard_describe_set() {
    local dir=$1 field=$2 file count=0 first='' signature='' text='' interval message
    case $field in
        messages)
            for file in "$dir/messages"/[0-9][0-9][0-9]; do
                [[ -f $file ]] || continue
                ka_wizard_read_set "$file"
                count=$((count + 1))
                ((count == 1)) && first=$REPLY
                # Length-prefixed, so no message text can imitate a field boundary.
                signature+="${#REPLY}:${file##*/}:$REPLY;"
            done
            if ((count == 1)); then text="1 message: $first"; else text="$count messages, first: $first"; fi
            ;;
        main)
            ka_wizard_read_set "$dir/main_interval"; signature=$REPLY
            text='?'
            if [[ $signature =~ ^[0-9]+$ ]]; then ka_format_duration_set "$signature"; text=$REPLY; fi
            ;;
        secondary)
            ka_wizard_read_set "$dir/secondary_enabled"
            if [[ $REPLY == 1 ]]; then
                ka_wizard_read_set "$dir/secondary_interval"; interval=$REPLY
                ka_wizard_read_set "$dir/secondary_message"; message=$REPLY
                signature="1"$'\037'"$interval"$'\037'"$message"
                text="once after ?: $message"
                if [[ $interval =~ ^[0-9]+$ ]]; then
                    ka_format_duration_set "$interval"; text="once after $REPLY: $message"
                fi
            else
                signature=0
                text='off'
            fi
            ;;
        notifications)
            ka_wizard_read_set "$dir/notifications"; signature=$REPLY
            if [[ $signature == 1 ]]; then text='ON'; else text='OFF'; fi
            ;;
        delivery)
            ka_wizard_read_set "$dir/delivery_mode"; signature=$REPLY
            if [[ $signature == ENTER_ONLY ]]; then text='ENTER ONLY'; else text='MESSAGE + ENTER'; fi
            ;;
        profile)
            ka_wizard_read_set "$dir/profile_update"; signature=${REPLY:-1}
            if [[ $signature == 0 ]]; then text='no, this keep-alive only'; else text='yes'; fi
            ;;
    esac
    KA_WIZARD_SIGNATURE=$signature
    REPLY=$text
}

# Role: Recompute every field's description for the original (WAS) or edited (NOW) copy.
# Done once per edit rather than per frame: the list redraws every second.
ka_wizard_describe_all() {
    local dir=$1 which=$2 i
    for i in "${!KA_WIZARD_FIELDS[@]}"; do
        ka_wizard_describe_set "$dir" "${KA_WIZARD_FIELDS[$i]}"
        if [[ $which == WAS ]]; then
            KA_WIZ_WAS_TEXT[$i]=$REPLY
            KA_WIZ_WAS_SIG[$i]=$KA_WIZARD_SIGNATURE
        else
            KA_WIZ_NOW_TEXT[$i]=$REPLY
            KA_WIZ_NOW_SIG[$i]=$KA_WIZARD_SIGNATURE
        fi
    done
}

# Role: Report whether any field differs from the configuration the editor opened with.
ka_wizard_dirty() {
    local i
    for i in "${!KA_WIZARD_FIELDS[@]}"; do
        [[ ${KA_WIZ_NOW_SIG[$i]} == "${KA_WIZ_WAS_SIG[$i]}" ]] || return 0
    done
    return 1
}

# Role: Keep the edited target's live countdowns in KA_WIZ_MAIN_LEFT/KA_WIZ_SEC_LEFT.
# The daemon republishes the index every second only while a manager is watching, and
# every fifteen seconds otherwise, so an ACTIVE countdown is counted down locally from the
# last publication seen instead of standing still between them. It counts on the daemon's
# monotonic clock and follows its gap rule: a step longer than KEEPALIVE_SUSPEND_GAP, or
# a backward one, is a suspend or stall the daemon does not subtract, so neither does the
# display. Time spent in a field screen is not such a gap (KA_WIZ_AWAY marks it).
ka_wizard_live_refresh() {
    local uuid=$1 now elapsed step gap
    if ! ka_now_monotonic; then
        # No clock: show the published values as they are.
        now=0
        KA_WIZ_LOADED_AT=0
    else
        now=$REPLY
    fi
    if ka_tui_index_changed || ((KA_WIZ_LOADED_AT == 0)); then
        ka_tui_load_index
        ka_tui_load_target_fields "$uuid" || true
        ka_tui_detail_overlay_index "$uuid" || true
        KA_WIZ_LOADED_AT=$now
        KA_WIZ_BASE_MAIN=$KA_F_MAIN_REMAIN
        KA_WIZ_BASE_SEC=$KA_F_SEC_REMAIN
        [[ $KA_WIZ_BASE_MAIN =~ ^[0-9]+$ ]] || KA_WIZ_BASE_MAIN=0
        [[ $KA_WIZ_BASE_SEC =~ ^[0-9]+$ ]] || KA_WIZ_BASE_SEC=0
    elif ((KA_WIZ_AWAY == 0 && KA_WIZ_LAST_DRAW > 0)); then
        ka_tunable KEEPALIVE_SUSPEND_GAP 2; gap=$REPLY
        step=$((now - KA_WIZ_LAST_DRAW))
        if ((step < 0 || step > gap)); then
            KA_WIZ_BASE_MAIN=$KA_WIZ_MAIN_LEFT
            KA_WIZ_BASE_SEC=$KA_WIZ_SEC_LEFT
            KA_WIZ_LOADED_AT=$now
        fi
    fi
    KA_WIZ_AWAY=0
    KA_WIZ_LAST_DRAW=$now
    elapsed=$((now - KA_WIZ_LOADED_AT))
    if ((now == 0 || elapsed < 0)) || [[ $KA_F_STATUS != ACTIVE ]]; then elapsed=0; fi
    KA_WIZ_MAIN_LEFT=$((KA_WIZ_BASE_MAIN - elapsed))
    if ((KA_WIZ_MAIN_LEFT < 0)); then KA_WIZ_MAIN_LEFT=0; fi
    KA_WIZ_SEC_LEFT=$KA_WIZ_BASE_SEC
    if [[ $KA_F_SEC_ENABLED == 1 && ${KA_F_SEC_DONE:-0} != 1 ]]; then
        KA_WIZ_SEC_LEFT=$((KA_WIZ_BASE_SEC - elapsed))
        if ((KA_WIZ_SEC_LEFT < 0)); then KA_WIZ_SEC_LEFT=0; fi
    fi
}

# Role: Phrase one countdown's fate under a new interval into REPLY: kept, or capped.
# The daemon applies the same rule when the request is saved.
ka_wizard_countdown_effect_set() {
    local label=$1 left=$2 interval=$3 left_text
    [[ $left =~ ^[0-9]+$ ]] || left=0
    [[ $interval =~ ^[0-9]+$ ]] || interval=0
    ka_format_duration_set "$left"; left_text=$REPLY
    ka_format_duration_set "$interval"
    if ((left > interval)); then
        REPLY="$label: $left_text left, capped at $REPLY on save."
    elif [[ $KA_F_STATUS == PAUSED ]]; then
        REPLY="$label stays paused with $left_text left."
    else
        REPLY="$label keeps running: $left_text left."
    fi
}

# Role: Explain into KA_WIZ_EFFECTS what saving would do to the target's countdowns.
# Mirrors ka_state_apply_request_configuration, which is authoritative. Countdown effects
# come first: the list shows the first effect on its own line and the rest on a second.
ka_wizard_effects() {
    local command=$1 interval enabled was_enabled rotation=''
    KA_WIZ_EFFECTS=()
    if [[ $command == CREATE ]]; then
        KA_WIZ_EFFECTS=('Press s to start this keep-alive with these settings.')
        return 0
    fi
    if ! ka_wizard_dirty; then
        if [[ $KA_F_STATUS == PAUSED ]]; then
            KA_WIZ_EFFECTS=('No changes yet. This keep-alive is paused; its countdowns are frozen.')
        else
            KA_WIZ_EFFECTS=('No changes yet. The countdowns keep running while you edit.')
        fi
        return 0
    fi
    if [[ ${KA_WIZ_NOW_SIG[1]} != "${KA_WIZ_WAS_SIG[1]}" ]]; then
        ka_wizard_read_set "$KA_WIZ_DIR/main_interval"; interval=$REPLY
        ka_wizard_countdown_effect_set 'Main countdown' "$KA_WIZ_MAIN_LEFT" "$interval"
        KA_WIZ_EFFECTS+=("$REPLY")
    fi
    if [[ ${KA_WIZ_NOW_SIG[2]} != "${KA_WIZ_WAS_SIG[2]}" ]]; then
        ka_wizard_read_set "$KA_WIZ_DIR/secondary_enabled"; enabled=$REPLY
        ka_wizard_read_set "$KA_WIZ_ORIGINAL/secondary_enabled"; was_enabled=$REPLY
        ka_wizard_read_set "$KA_WIZ_DIR/secondary_interval"; interval=$REPLY
        if [[ $enabled != 1 ]]; then
            KA_WIZ_EFFECTS+=('Secondary prompt turns off; an owed secondary Enter is dropped.')
        elif [[ $was_enabled != 1 || ${KA_F_SEC_DONE:-0} == 1 ]]; then
            [[ $interval =~ ^[0-9]+$ ]] || interval=0
            ka_format_duration_set "$interval"
            if [[ $KA_F_STATUS == PAUSED ]]; then
                KA_WIZ_EFFECTS+=("Secondary prompt armed at $REPLY; it counts once the target resumes.")
            else
                KA_WIZ_EFFECTS+=("Secondary prompt armed: it fires once, $REPLY after saving.")
            fi
        else
            ka_wizard_countdown_effect_set 'Secondary countdown' "$KA_WIZ_SEC_LEFT" "$interval"
            KA_WIZ_EFFECTS+=("$REPLY")
        fi
    fi
    if [[ ${KA_WIZ_NOW_SIG[0]} != "${KA_WIZ_WAS_SIG[0]}" ]]; then
        rotation='Messages changed: the rotation restarts at message 1, and an owed Enter is dropped.'
        KA_WIZ_EFFECTS+=("$rotation")
    fi
    ((${#KA_WIZ_EFFECTS[@]} > 0)) || KA_WIZ_EFFECTS=('Saving does not reset either countdown.')
}

# Role: Draw the settings list: live countdowns, every field with its change marker, and
# what saving would do. Fork-free, because it redraws every second while the editor is open.
ka_wizard_editor_render() {
    local uuid=$1 command=$2 selected=$3 i value marker width bar_w frozen note effect
    ka_tui_frame_begin
    # Header 2-3, timers 2, fields 6 with spacing 2, effects 2, hint 2, border 1, toast 2.
    ka_wizard_too_small 20 && return 0
    ka_wizard_header "$KA_I_CONFIG" 'Settings'
    if [[ $command == CONFIGURE ]]; then
        ka_wizard_live_refresh "$uuid"
        bar_w=16
        ((${KA_TUI_COLS:-80} < 76)) && bar_w=10
        frozen=''
        [[ $KA_F_STATUS == PAUSED || $KA_F_STATUS == UNAVAILABLE ]] && frozen=' · frozen'
        [[ ${KA_ASCII_MODE:-0} == 1 && -n $frozen ]] && frozen=' (frozen)'
        ka_tui_render_timer_row MAIN "$KA_WIZ_MAIN_LEFT" "${KA_F_MAIN_INTERVAL:-0}" "$bar_w" "$frozen"
        if [[ $KA_F_SEC_ENABLED == 1 ]]; then
            note=$frozen
            if [[ ${KA_F_SEC_DONE:-0} == 1 ]]; then
                note=' · sent (one-shot)'
                [[ ${KA_ASCII_MODE:-0} == 1 ]] && note=' (sent, one-shot)'
            fi
            ka_tui_render_timer_row SECONDARY "$KA_WIZ_SEC_LEFT" "${KA_F_SEC_INTERVAL:-0}" "$bar_w" "$note"
        else
            printf '%s  SECONDARY  disabled\033[K\n' "$KA_G_V"
        fi
    else
        ka_tui_field_width_set 4; width=$REPLY
        ka_tui_truncate_set 'New keep-alive: its countdowns start when you save.' "$width"
        printf '%s  %s\033[K\n%s\033[K\n' "$KA_G_V" "$REPLY" "$KA_G_V"
    fi
    printf '%s\033[K\n' "$KA_G_V"
    ka_tui_field_width_set 14 10; width=$REPLY
    for i in "${!KA_WIZARD_FIELDS[@]}"; do
        marker=''
        value=${KA_WIZ_NOW_TEXT[$i]}
        if [[ ${KA_WIZ_NOW_SIG[$i]} != "${KA_WIZ_WAS_SIG[$i]}" ]]; then
            marker=" ${KA_YELLOW}*${KA_RESET}"
            # Short values read best as before -> after; long ones just show the new text.
            case ${KA_WIZARD_FIELDS[$i]} in
                main|notifications|delivery|profile) value="${KA_WIZ_WAS_TEXT[$i]} $KA_G_CUR $value" ;;
            esac
        fi
        printf -v value '%-16s %s' "${KA_WIZARD_LABELS[$i]}" "$value"
        ka_tui_truncate_set "$value" "$width"
        if ((i == selected)); then
            printf '%s  %s%s%s %d%s  %s%s%s%s\033[K\n' "$KA_G_V" "$KA_CYAN" "$KA_BOLD" "$KA_G_SEL" \
                "$((i + 1))" "$KA_RESET" "$KA_BOLD" "$REPLY" "$KA_RESET" "$marker"
        else
            printf '%s    %s%d%s  %s%s\033[K\n' "$KA_G_V" "$KA_DIM" "$((i + 1))" "$KA_RESET" \
                "$REPLY" "$marker"
        fi
    done
    printf '%s\033[K\n' "$KA_G_V"
    ka_wizard_effects "$command"
    ka_tui_field_width_set 4; width=$REPLY
    ka_tui_truncate_set "${KA_WIZ_EFFECTS[0]}" "$width"
    printf '%s  %s\033[K\n' "$KA_G_V" "$REPLY"
    if ((${#KA_WIZ_EFFECTS[@]} > 1)); then
        # Two rows fit at the minimum height, so any further effects share the second.
        effect=${KA_WIZ_EFFECTS[1]}
        for i in "${KA_WIZ_EFFECTS[@]:2}"; do effect+=" $i"; done
        ka_tui_truncate_set "$effect" "$width"
        printf '%s  %s\033[K\n' "$KA_G_V" "$REPLY"
    fi
    ka_wizard_hint 'up/down select    1-6 or Enter change    s save    Esc close' \
        'Enter change  s save  Esc close'
    ka_tui_box_bottom
    ka_tui_render_toast
    ka_tui_frame_end
}

# Role: Open the sub-editor for one field, or flip the profile choice in place, then
# refresh the list's descriptions. A sub-editor's cancel leaves the field as it was.
ka_wizard_edit_field() {
    local index=$1 type=$2 name=$3
    case ${KA_WIZARD_FIELDS[$index]} in
        messages) ka_wizard_step_messages "$KA_WIZ_DIR" "$type" "$name" || true ;;
        main) ka_wizard_step_main_interval "$KA_WIZ_DIR" || true ;;
        secondary) ka_wizard_step_secondary "$KA_WIZ_DIR" || true ;;
        notifications) ka_wizard_step_notifications "$KA_WIZ_DIR" || true ;;
        delivery) ka_wizard_step_delivery "$KA_WIZ_DIR" || true ;;
        profile)
            ka_wizard_read_set "$KA_WIZ_DIR/profile_update"
            if [[ $REPLY == 0 ]]; then
                ka_write_scalar "$KA_WIZ_DIR/profile_update" 1 || true
            else
                ka_write_scalar "$KA_WIZ_DIR/profile_update" 0 || true
            fi
            ;;
    esac
    # Time in a field screen is not a suspend; the next list frame counts it normally.
    KA_WIZ_AWAY=1
    ka_wizard_describe_all "$KA_WIZ_DIR" NOW
}

# Role: Ask before closing the editor with unsaved changes; succeed only on an explicit yes.
ka_wizard_confirm_discard() {
    local width
    while true; do
        ka_tui_frame_begin
        ka_tui_field_width_set 30 8; width=$REPLY
        ka_tui_box_top "$KA_I_WARN" 'Unsaved changes'
        ka_tui_truncate_set "${KA_WIZARD_SUBJECT-}" "$width"
        printf '%s Discard the changes for %s?\033[K\n' "$KA_G_V" "$REPLY"
        printf '%s No edits have been saved; the keep-alive'\''s settings are unchanged.\033[K\n' "$KA_G_V"
        printf '%s\033[K\n%s y discard     n/Esc keep editing\033[K\n' "$KA_G_V" "$KA_G_V"
        ka_tui_box_bottom
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        case $KA_KEY in
            y|Y) return 0 ;;
            n|N|ESC) return 1 ;;
        esac
    done
}

# Role: Submit the edited configuration as one CREATE or CONFIGURE request.
# The scratch copy is kept until the daemon accepts it, so a refusal leaves the user in the
# editor with every change intact; the reason is shown as a toast.
ka_wizard_submit() {
    local uuid=$1 command=$2 tmp=$3 id req response=''
    if ! ka_ipc_new_request "$command" "$uuid" >/dev/null; then
        ka_tui_toast 'Could not prepare the request; nothing was saved.'
        return 1
    fi
    id=$KA_IPC_REQUEST_ID
    req=$(ka_ipc_request_dir "$id")
    if ! cp -a -- "$tmp/config" "$req/config"; then
        rm -rf -- "$req"
        ka_tui_toast 'Could not stage the settings; nothing was saved.'
        return 1
    fi
    if ! ka_ipc_signal_request "$id"; then
        rm -rf -- "$req"
        ka_tui_toast 'The keep-alive service did not take the request; nothing was saved.'
        return 1
    fi
    response=$(ka_ipc_wait_response "$id") || true
    if [[ $response == OK$'\t'* ]]; then
        if [[ $command == CREATE ]]; then
            ka_tui_toast 'Keep-alive created.'
        else
            ka_tui_toast 'Settings saved.'
        fi
        return 0
    fi
    response=${response#*$'\t'}
    ka_tui_toast "${response:-No answer from the keep-alive service; nothing was saved.}"
    return 1
}

# Role: Run the settings editor for one target and submit CREATE/CONFIGURE when saved.
# Returns 0 only when the daemon accepted the change; closing without saving returns 1.
ka_tui_run_wizard() {
    local uuid=$1 status=$2 type=$3 name=$4 tmp command selected=0 key
    KA_WIZARD_SUBJECT="$type / $name"
    if [[ $status == AVAILABLE ]]; then
        KA_WIZARD_ACTION=Create
        command=CREATE
    else
        KA_WIZARD_ACTION=Configure
        command=CONFIGURE
    fi
    tmp=$(mktemp -d "$KA_RUNTIME_DIR/wizard.XXXXXX") || return 1
    # Publish the scratch path so ka_tui_leave removes it on Ctrl-C, SIGTERM, or exit.
    KA_TUI_SCRATCH=$tmp
    mkdir -p "$tmp/config" || { ka_wizard_discard "$tmp"; return 1; }
    if [[ $command == CREATE ]]; then
        ka_profile_copy_to_request "$tmp/config" || { ka_wizard_discard "$tmp"; return 1; }
    else
        ka_state_copy_target_to_request "$uuid" "$tmp/config" || { ka_wizard_discard "$tmp"; return 1; }
    fi
    # The default-profile choice travels in the request; yes is the historical behavior.
    if [[ ! -e $tmp/config/profile_update ]]; then
        ka_write_scalar "$tmp/config/profile_update" 1 || { ka_wizard_discard "$tmp"; return 1; }
    fi
    # The untouched copy is what change markers and the discard prompt compare against.
    cp -a -- "$tmp/config" "$tmp/original" || { ka_wizard_discard "$tmp"; return 1; }
    KA_WIZ_DIR=$tmp/config
    KA_WIZ_ORIGINAL=$tmp/original
    KA_WIZ_LOADED_AT=0
    KA_WIZ_LAST_DRAW=0
    KA_WIZ_AWAY=0
    ka_wizard_describe_all "$KA_WIZ_ORIGINAL" WAS
    ka_wizard_describe_all "$KA_WIZ_DIR" NOW

    while true; do
        ka_wizard_editor_render "$uuid" "$command" "$selected"
        # One second, not the field screens' sixty: the countdowns above are live.
        ka_tui_read_key 1 || continue
        key=$KA_KEY
        case $key in
            UP|k) if ((selected > 0)); then selected=$((selected - 1)); fi ;;
            DOWN|j) if ((selected + 1 < ${#KA_WIZARD_FIELDS[@]})); then selected=$((selected + 1)); fi ;;
            [1-6])
                selected=$((key - 1))
                ka_wizard_edit_field "$selected" "$type" "$name"
                ;;
            ENTER|RIGHT) ka_wizard_edit_field "$selected" "$type" "$name" ;;
            s|S)
                if ka_wizard_submit "$uuid" "$command" "$tmp"; then
                    ka_wizard_discard "$tmp"
                    return 0
                fi
                ;;
            ESC|q|Q)
                if ! ka_wizard_dirty || ka_wizard_confirm_discard; then
                    ka_wizard_discard "$tmp"
                    return 1
                fi
                KA_WIZ_AWAY=1
                ;;
        esac
    done
}

# Role: Remove one editor scratch directory and clear the exit-time cleanup handle.
ka_wizard_discard() {
    local tmp=$1
    rm -rf -- "$tmp"
    [[ ${KA_TUI_SCRATCH:-} == "$tmp" ]] && KA_TUI_SCRATCH=''
    return 0
}
