#!/usr/bin/env bash
# High-level manager, target detail, logs, and interactive client screens.

# Role: Map AI client names to stable sorting groups (Claude, Codex, Kimi, then others).
# Sets REPLY instead of printing: this runs once per row per frame, and a command
# substitution here costs a fork every time.
ka_tui_type_rank() {
    case $1 in Claude) REPLY=10;; Codex) REPLY=20;; Kimi) REPLY=30;; *) REPLY=40;; esac
}

# Role: Map target states to the agreed ACTIVE, PAUSED, UNAVAILABLE, AVAILABLE sort order.
# Sets REPLY for the same per-row cost reason as ka_tui_type_rank.
ka_tui_status_rank() {
    case $1 in ACTIVE) REPLY=10;; PAUSED) REPLY=20;; UNAVAILABLE) REPLY=30;; AVAILABLE) REPLY=40;; *) REPLY=50;; esac
}

# Role: Load and sort the daemon's atomic index snapshot into TUI row arrays.
# Rows are split without `read` so empty columns survive: tab is IFS whitespace, which
# silently merges adjacent delimiters and shifts every later field. Sorting streams
# through one pipeline rather than a runtime temp file that leaked on interrupt.
ka_tui_load_index() {
    declare -ga KA_R_UUID=() KA_R_TYPE=() KA_R_NAME=() KA_R_DIR=() KA_R_STATUS=()
    declare -ga KA_R_MAIN_REMAIN=() KA_R_MAIN_INTERVAL=() KA_R_SEC_ENABLED=() KA_R_SEC_REMAIN=()
    declare -ga KA_R_SEC_INTERVAL=() KA_R_MODE=() KA_R_NOTIFY=() KA_R_LAST=() KA_R_REASON=()
    [[ -r $KA_INDEX_FILE ]] || return 0

    local sorted rest
    while IFS= read -r sorted; do
        # Drop the three synthetic sort keys without disturbing the original columns.
        rest=${sorted#*$'\t'}; rest=${rest#*$'\t'}; rest=${rest#*$'\t'}
        ka_tui_split_tsv "$rest"
        KA_R_UUID+=("${KA_TSV[0]-}") KA_R_TYPE+=("${KA_TSV[1]-}") KA_R_NAME+=("${KA_TSV[2]-}")
        KA_R_DIR+=("${KA_TSV[3]-}") KA_R_STATUS+=("${KA_TSV[4]-}")
        KA_R_MAIN_REMAIN+=("${KA_TSV[5]:-0}") KA_R_MAIN_INTERVAL+=("${KA_TSV[6]:-0}")
        KA_R_SEC_ENABLED+=("${KA_TSV[7]:-0}") KA_R_SEC_REMAIN+=("${KA_TSV[8]:-0}")
        KA_R_SEC_INTERVAL+=("${KA_TSV[9]:-0}") KA_R_MODE+=("${KA_TSV[10]-}")
        KA_R_NOTIFY+=("${KA_TSV[11]:-0}") KA_R_LAST+=("${KA_TSV[12]-}") KA_R_REASON+=("${KA_TSV[13]-}")
    done < <(ka_tui_sort_index_rows)
}

# Role: Emit index rows prefixed with family/type/state sort keys for one ordering pass.
ka_tui_sort_index_rows() {
    local line type lower rank srank
    while IFS= read -r line; do
        [[ -n $line ]] || continue
        ka_tui_split_tsv "$line"
        [[ -n ${KA_TSV[0]-} ]] || continue
        type=${KA_TSV[1]-}
        lower=${type,,}
        ka_tui_type_rank "$type"; rank=$REPLY
        ka_tui_status_rank "${KA_TSV[4]-}"; srank=$REPLY
        printf '%03d\t%s\t%03d\t%s\n' "$rank" "$lower" "$srank" "$line"
    done <"$KA_INDEX_FILE" | sort -t $'\t' -k1,1n -k2,2f -k3,3n -k6,6f
}

# Role: Read one target checkpoint once into KA_F_* fields for detail rendering.
# The previous per-field accessor reparsed state.tsv in a subshell for every value,
# costing roughly two dozen forks and file scans per detail frame.
ka_tui_load_target_fields() {
    local uuid=$1 file line key value
    KA_F_TYPE='' KA_F_NAME='' KA_F_DIR='' KA_F_STATUS='' KA_F_MODE='' KA_F_NOTIFY=''
    KA_F_MAIN_REMAIN=0 KA_F_MAIN_INTERVAL=0 KA_F_MAIN_INDEX=0
    KA_F_SEC_ENABLED=0 KA_F_SEC_REMAIN=0 KA_F_SEC_INTERVAL=0 KA_F_SEC_DONE=0
    KA_F_LAST='' KA_F_REASON=''
    ka_state_target_dir "$uuid"
    file="$REPLY/state.tsv"
    [[ -r $file ]] || return 1
    while IFS= read -r line; do
        if [[ $line == *$'\t'* ]]; then
            key=${line%%$'\t'*}
            value=${line#*$'\t'}
        else
            key=$line
            value=''
        fi
        case $key in
            type) KA_F_TYPE=$value ;;
            name) KA_F_NAME=$value ;;
            directory) KA_F_DIR=$value ;;
            status) KA_F_STATUS=$value ;;
            mode) KA_F_MODE=$value ;;
            notifications) KA_F_NOTIFY=$value ;;
            main_remaining) KA_F_MAIN_REMAIN=$value ;;
            main_interval) KA_F_MAIN_INTERVAL=$value ;;
            main_index) KA_F_MAIN_INDEX=$value ;;
            secondary_enabled) KA_F_SEC_ENABLED=$value ;;
            secondary_remaining) KA_F_SEC_REMAIN=$value ;;
            secondary_interval) KA_F_SEC_INTERVAL=$value ;;
            secondary_done) KA_F_SEC_DONE=$value ;;
            last_seen) KA_F_LAST=$value ;;
            reason) KA_F_REASON=$value ;;
        esac
    done <"$file"
}

# Role: Report whether the published index differs from the copy this client last parsed.
# Slurped with `read`, not a command substitution, so an unchanged frame costs no fork.
ka_tui_index_changed() {
    local content=''
    if [[ -r $KA_INDEX_FILE ]]; then
        IFS= read -r -d '' content <"$KA_INDEX_FILE" || true
    fi
    [[ $content != "${KA_TUI_INDEX_CACHE-}" ]] || return 1
    KA_TUI_INDEX_CACHE=$content
    return 0
}

# Role: Count manager rows by state for the dashboard summary line.
ka_tui_state_count() {
    local wanted=$1 status count=0
    for status in "${KA_R_STATUS[@]}"; do [[ $status == "$wanted" ]] && ((count += 1)); done
    printf '%d' "$count"
}

# Role: Restore a highlighted UUID after live refresh so rows do not jump under the user.
ka_tui_find_uuid_index() {
    local uuid=$1 i
    for i in "${!KA_R_UUID[@]}"; do [[ ${KA_R_UUID[$i]} == "$uuid" ]] && { printf '%d' "$i"; return 0; }; done
    return 1
}

# Role: Derive the manager's session-name column from live width so rows never wrap.
ka_tui_row_name_width() {
    local width=$((${KA_TUI_COLS:-80} - 65))
    ((width < 16)) && width=16
    ((width > 48)) && width=48
    printf '%d' "$width"
}

# Role: Render one manager row in full-width table form with compact timer depletion bar.
ka_tui_render_row_full() {
    local i=$1 selected=$2 number=$3 name_w=$4 marker=' ' type name status mr mi se sr pad
    ((i == selected)) && marker=$KA_G_SEL
    type=${KA_R_TYPE[$i]}; status=${KA_R_STATUS[$i]}
    mr=${KA_R_MAIN_REMAIN[$i]}; mi=${KA_R_MAIN_INTERVAL[$i]}
    se=${KA_R_SEC_ENABLED[$i]}; sr=${KA_R_SEC_REMAIN[$i]}
    name=$(ka_tui_truncate "${KA_R_NAME[$i]}" "$name_w")
    printf ' %s %2d ' "$marker" "$number"
    [[ -n $KA_I_AI ]] && printf '%s ' "$KA_I_AI"
    printf '%-10s %-*s ' "$(ka_tui_truncate "$type" 10)" "$name_w" "$name"
    ka_tui_status "$status"
    # Pad from the rendered cell count, not the bare word: the icon adds two cells and
    # used to shift every following column between --no-icons and icon mode.
    pad=$((14 - $(ka_tui_status_width "$status")))
    ((pad < 1)) && pad=1
    printf '%*s' "$pad" ''
    if [[ $status == ACTIVE || $status == PAUSED ]]; then
        ka_tui_progress "$mr" "$mi" 10
        printf ' %-8s ' "$(ka_format_duration "$mr")"
        # Last column: no padding, so rows carry no trailing whitespace.
        if [[ $se == 1 ]]; then printf '%s' "$(ka_format_duration "$sr")"; else printf '%s' "$KA_G_NONE"; fi
    else
        printf '%s' "$KA_G_NONE"
    fi
    printf '\033[K\n'
}

# Role: Render one manager row in narrow stacked form when terminal width is constrained.
ka_tui_render_row_compact() {
    local i=$1 selected=$2 number=$3 marker=' ' status mr mi se sr name_w
    ((i == selected)) && marker=$KA_G_SEL
    status=${KA_R_STATUS[$i]}; mr=${KA_R_MAIN_REMAIN[$i]}; mi=${KA_R_MAIN_INTERVAL[$i]}
    se=${KA_R_SEC_ENABLED[$i]}; sr=${KA_R_SEC_REMAIN[$i]}
    name_w=$(ka_tui_field_width 22 12)
    printf ' %s %2d %-10s / %s\033[K\n' "$marker" "$number" \
        "$(ka_tui_truncate "${KA_R_TYPE[$i]}" 10)" "$(ka_tui_truncate "${KA_R_NAME[$i]}" "$name_w")"
    printf '      '; ka_tui_status "$status"
    if [[ $status == ACTIVE || $status == PAUSED ]]; then
        printf '   '; ka_tui_progress "$mr" "$mi" 10; printf ' %s' "$(ka_format_duration "$mr")"
        [[ $se == 1 ]] && printf '   S %s' "$(ka_format_duration "$sr")"
    fi
    printf '\033[K\n'
}

# Role: Draw the manager header as a colored segment bar, falling back to the plain box.
# The bar needs color; --no-color, NO_COLOR, and a too-narrow terminal all take the box
# path, so every legacy presentation mode still renders a complete, readable header.
ka_tui_render_manager_header() {
    local n=$1 active=$2 paused=$3 available=$4 unavailable=$5 summary now
    now=$(ka_now_hms)
    if ka_tui_bar_supported; then
        ka_tui_bar_begin
        ka_tui_bar_add 4 7 "$(ka_icon_label "$KA_I_AI" 'Keep Alive')" 1
        ka_tui_bar_add 2 0 "$(ka_icon_label "$KA_I_SERVICE" 'online')"
        ka_tui_bar_add 0 7 "$n sessions"
        # Zero counts are omitted so the bar stays short and only shows live facts.
        ((active > 0)) && ka_tui_bar_add 1 7 "$active active"
        ((paused > 0)) && ka_tui_bar_add 3 0 "$paused paused"
        ((available > 0)) && ka_tui_bar_add 6 0 "$available available"
        ((unavailable > 0)) && ka_tui_bar_add 5 7 "$unavailable lost"
        ka_tui_bar_add 0 7 "$now"
        ka_tui_bar_end
        if ka_tui_bar_flush; then
            printf '\033[K\n'
            return 0
        fi
    fi

    summary=$(ka_icon_label "$KA_I_SERVICE" 'service online')
    if ((${KA_TUI_COLS:-80} >= 88)); then
        summary+=$(printf '   %d AI sessions   %d active   %d paused   %d available   %d unavailable' \
            "$n" "$active" "$paused" "$available" "$unavailable")
    else
        summary+=$(printf '   %d sessions  %dA %dP %dV %dX' "$n" "$active" "$paused" "$available" "$unavailable")
    fi
    ka_tui_box_top "$KA_I_AI" 'Keep Alive Manager' "$now"
    # Truncated unconditionally: the counts are unbounded, so no fixed threshold is safe.
    printf '%s %s\033[K\n' "$KA_G_V" "$(ka_tui_truncate "$summary" "$(ka_tui_field_width 2)")"
    ka_tui_box_bottom
    printf '\033[K\n'
}

# Role: Render the canonical manager overview while adapting to terminal dimensions.
ka_tui_render_manager() {
    local selected=$1 offset=$2 cols lines max_rows end i n active paused available unavailable
    ka_tui_frame_begin
    if ka_tui_too_small 52 14; then
        ka_tui_render_too_small 52 14
        ka_tui_frame_end
        return
    fi
    cols=${KA_TUI_COLS}; lines=${KA_TUI_LINES}
    n=${#KA_R_UUID[@]}
    active=$(ka_tui_state_count ACTIVE); paused=$(ka_tui_state_count PAUSED)
    available=$(ka_tui_state_count AVAILABLE); unavailable=$(ka_tui_state_count UNAVAILABLE)

    ka_tui_render_manager_header "$n" "$active" "$paused" "$available" "$unavailable"

    max_rows=$((lines - 9)); ((max_rows < 3)) && max_rows=3
    end=$((offset + max_rows)); ((end > n)) && end=$n
    if ((cols >= 92)); then
        local name_w
        name_w=$(ka_tui_row_name_width)
        printf '    TYPE       %-*s KEEP-ALIVE     MAIN       NUDGE\033[K\n' "$name_w" 'SESSION'
        ka_tui_hrule 2
        for ((i=offset; i<end; i++)); do ka_tui_render_row_full "$i" "$selected" "$((i + 1))" "$name_w"; done
    else
        for ((i=offset; i<end; i++)); do ka_tui_render_row_compact "$i" "$selected" "$((i + 1))"; done
    fi
    if ((n > max_rows)); then
        printf '\033[K\n  showing %d-%d of %d\033[K\n' "$((offset + 1))" "$end" "$n"
    fi
    if ((cols >= 78)); then
        printf '\033[K\n  up/down or j/k navigate    1-9 select    Enter open    r refresh    q quit\033[K\n'
    else
        printf '\033[K\n  j/k move  1-9 pick  Enter open  r refresh  q quit\033[K\n'
    fi
    ka_tui_render_toast
    ka_tui_frame_end
}

# Role: Submit one simple target action and convert daemon response into a transient toast.
ka_tui_action() {
    local command=$1 uuid=$2 value=${3-} response
    response=$(ka_ipc_call "$command" "$uuid" "$value" 2>/dev/null || true)
    if [[ $response == OK$'\t'* ]]; then ka_tui_toast "${response#*$'\t'}"; return 0; fi
    ka_tui_toast "${response#*$'\t'}"
    return 1
}

# Role: Confirm destructive deletion without allowing a single accidental keypress to remove state.
ka_tui_confirm_delete() {
    local name=$1 key width
    while true; do
        ka_tui_frame_begin
        width=$(ka_tui_field_width 4)
        ka_tui_box_top "$KA_I_DELETE" 'Delete Keep Alive'
        printf '%s Delete keep-alive for %s?\033[K\n' "$KA_G_V" "$(ka_tui_truncate "$name" "$((width - 24))")"
        printf '%s This removes only manager state and this target'\''s runtime event history.\n' "$KA_G_V"
        printf '%s The AI process and Konsole tab are never terminated.\033[K\n' "$KA_G_V"
        printf '%s\033[K\n%s y delete     n/Esc cancel\033[K\n' "$KA_G_V" "$KA_G_V"
        ka_tui_box_bottom
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in y|Y) return 0;; n|N|ESC) return 1;; esac
    done
}

# Role: Render recent per-target events in the detailed keep-alive screen.
ka_tui_render_recent_events() {
    local uuid=$1 max=${2:-6} time event detail result detail_w
    ka_tui_box_mid "$KA_I_LOG" 'Recent events'
    detail_w=$(ka_tui_field_width 38 12)
    while IFS=$'\t' read -r time event detail result; do
        printf '%s  %-8s %-11s %-*s %s\033[K\n' "$KA_G_V" "$time" "$event" \
            "$detail_w" "$(ka_tui_truncate "$detail" "$detail_w")" "$(ka_tui_truncate "$result" 12)"
    done < <(ka_log_tail "$uuid" "$max")
}

# Role: Draw the detail header as a colored segment bar, falling back to the plain box.
# Reads the KA_F_* fields loaded by the caller; adds no extra checkpoint parse.
ka_tui_render_detail_header() {
    local title now
    title=$(ka_icon_label "$KA_I_AI" "$(ka_tui_truncate "$KA_F_TYPE / $KA_F_NAME" 32)")
    now=$(ka_now_hms)
    if ka_tui_bar_supported; then
        ka_tui_status_colors "$KA_F_STATUS"
        ka_tui_bar_begin
        ka_tui_bar_add 4 7 "$title" 1
        ka_tui_bar_add "$KA_SEG_BG" "$KA_SEG_FG" "$KA_F_STATUS" 1
        ka_tui_bar_add 0 7 "main $(ka_format_duration "$KA_F_MAIN_REMAIN")"
        [[ $KA_F_SEC_ENABLED == 1 ]] && ka_tui_bar_add 0 7 "sec $(ka_format_duration "$KA_F_SEC_REMAIN")"
        ka_tui_bar_add 0 7 "$now"
        ka_tui_bar_end
        if ka_tui_bar_flush; then
            printf '%s\033[K\n' "$KA_G_V"
            return 0
        fi
    fi
    ka_tui_box_top "$KA_I_AI" "Keep Alive $(ka_tui_truncate "$KA_F_TYPE / $KA_F_NAME" 32)" "$now"
    printf '%s\033[K\n%s  Status          ' "$KA_G_V" "$KA_G_V"; ka_tui_status "$KA_F_STATUS"; printf '\n'
}

# Role: Render one existing keep-alive target detail view from atomic persisted state.
ka_tui_render_detail() {
    local uuid=$1 secondary cols frozen value_w bar_w
    ka_tui_load_target_fields "$uuid" || return 1
    ka_state_target_dir "$uuid"
    secondary=$(cat "$REPLY/secondary_message" 2>/dev/null || true)

    ka_tui_frame_begin
    if ka_tui_too_small 52 16; then
        ka_tui_render_too_small 52 16
        ka_tui_frame_end
        return
    fi
    cols=${KA_TUI_COLS}
    value_w=$(ka_tui_field_width 22 12)
    bar_w=16; ((cols < 76)) && bar_w=10
    frozen=''
    [[ $KA_F_STATUS == PAUSED || $KA_F_STATUS == UNAVAILABLE ]] && frozen=' · frozen'
    [[ ${KA_ASCII_MODE:-0} == 1 && -n $frozen ]] && frozen=' (frozen)'

    ka_tui_render_detail_header
    printf '%s  ' "$KA_G_V"; ka_icon_label "$KA_I_TERM" 'Target'; printf '          %s\n' "$(ka_tui_truncate "$KA_F_TYPE" "$value_w")"
    printf '%s  ' "$KA_G_V"; ka_icon_label "$KA_I_DIR" 'Directory'; printf '       %s\n' "$(ka_tui_truncate "$KA_F_DIR" "$value_w")"
    printf '%s  ' "$KA_G_V"; ka_icon_label "$KA_I_SESSION" 'Session'; printf '         %s\n' "$(ka_tui_truncate "$uuid" "$value_w")"
    printf '%s\033[K\n%s  ' "$KA_G_V" "$KA_G_V"; ka_icon_label "$KA_I_ENTER" 'Delivery'
    printf '        %s\033[K\n' "$([[ $KA_F_MODE == MESSAGE_ENTER ]] && printf 'MESSAGE + ENTER' || printf 'ENTER ONLY')"
    printf '%s  ' "$KA_G_V"; ka_icon_label "$KA_I_NOTIFY" 'Notification'
    printf '    %s\033[K\n' "$([[ $KA_F_NOTIFY == 1 ]] && printf ON || printf OFF)"

    if [[ $KA_F_STATUS == UNAVAILABLE ]]; then
        printf '%s\033[K\n%s  Last seen        %s\033[K\n%s  Reason           %s\033[K\n' "$KA_G_V" \
            "$KA_G_V" "$(ka_tui_truncate "$KA_F_LAST" "$value_w")" \
            "$KA_G_V" "$(ka_tui_truncate "$KA_F_REASON" "$value_w")"
        printf '%s\033[K\n%s  %s\033[K\n' "$KA_G_V" "$KA_G_V" \
            "$(ka_tui_truncate 'Timers are frozen. This record remains until you delete it.' "$(ka_tui_field_width 3)")"
    fi

    ka_tui_box_mid "$KA_I_TIMER" 'Timers'
    printf '%s\033[K\n' "$KA_G_V"
    ka_tui_render_timer_row MAIN "$KA_F_MAIN_REMAIN" "$KA_F_MAIN_INTERVAL" "$bar_w" "$frozen"
    if [[ $KA_F_SEC_ENABLED == 1 ]]; then
        local sec_note=$frozen
        # The secondary is a one-shot nudge; say so once it has fired.
        [[ ${KA_F_SEC_DONE:-0} == 1 ]] && sec_note=' · sent (one-shot)'
        ka_tui_render_timer_row SECONDARY "$KA_F_SEC_REMAIN" "$KA_F_SEC_INTERVAL" "$bar_w" "$sec_note"
        printf '%s  Prompt     %s\033[K\n' "$KA_G_V" "$(ka_tui_truncate "$secondary" "$(ka_tui_field_width 15 12)")"
    else
        printf '%s  SECONDARY  disabled\033[K\n' "$KA_G_V"
    fi

    ka_tui_box_mid "$KA_I_MESSAGE" 'Message rotation'
    ka_tui_render_message_rotation "$uuid" "$KA_F_MAIN_INDEX"
    [[ $KA_F_MODE == ENTER_ONLY ]] && printf '%s   Enter-only mode does not consume the queued message.\033[K\n' "$KA_G_V"
    ka_tui_render_recent_events "$uuid" 5
    ka_tui_box_bottom
    printf '\033[K\n'
    if [[ $KA_F_STATUS == UNAVAILABLE ]]; then
        printf '  l full logs   d delete   Esc back\033[K\n'
    elif ((cols >= 82)); then
        printf '  n main now   s secondary now   r reset main   p pause/resume\033[K\n'
        printf '  e enter once (resumes message+enter)      E enter-only from now on\033[K\n'
        printf '  c configure  l full logs       d delete       Esc back\033[K\n'
    else
        printf '  n main  s secondary  r reset  p pause\033[K\n'
        printf '  e enter once   E enter-only\033[K\n'
        printf '  c configure  l logs  d delete  Esc back\033[K\n'
    fi
    ka_tui_render_toast
    ka_tui_frame_end
}

# Role: Render one labeled countdown row, dropping the interval suffix on narrow terminals.
# The fixed-width form was the last line in the detail view that could still overrun 52 columns.
ka_tui_render_timer_row() {
    local label=$1 remain=$2 interval=$3 bar_w=$4 frozen=$5
    printf '%s  %-11s' "$KA_G_V" "$label"
    ka_tui_progress "$remain" "$interval" "$bar_w"
    if ((${KA_TUI_COLS:-80} >= 62)); then
        printf '  %-10s   interval %s%s\033[K\n' "$(ka_format_duration "$remain")" \
            "$(ka_format_duration "$interval")" "$frozen"
    else
        printf '  %s%s\033[K\n' "$(ka_format_duration "$remain")" "$frozen"
    fi
}

# Role: List a target's stored message rotation and mark the entry that fires next.
# Kept separate so the glob-option change stays local instead of leaking to the caller.
ka_tui_render_message_rotation() {
    local uuid=$1 index=$2 dir file number=0 marker text_w had_nullglob=0
    ka_state_target_dir "$uuid"; dir=$REPLY
    text_w=$(ka_tui_field_width 12 12)
    shopt -q nullglob && had_nullglob=1
    shopt -s nullglob
    for file in "$dir/messages"/[0-9][0-9][0-9]; do
        ((number += 1)); marker=' '
        ((number - 1 == index)) && marker=$KA_G_CUR
        printf '%s   %s %2d. %s\033[K\n' "$KA_G_V" "$marker" "$number" "$(ka_tui_truncate "$(cat -- "$file")" "$text_w")"
    done
    ((had_nullglob == 1)) || shopt -u nullglob
}

# Role: Provide a scrollable full per-target event-log viewer with vim-like navigation.
ka_tui_logs() {
    local uuid=$1 offset=0 key lines page total detail_w
    local -a log_lines=()
    while true; do
        mapfile -t log_lines < <(ka_log_all "$uuid")
        total=${#log_lines[@]}
        ka_tui_frame_begin
        if ka_tui_too_small 52 12; then
            ka_tui_render_too_small 52 12
            ka_tui_frame_end
            ka_tui_read_key 60 || continue
            [[ $KA_KEY == ESC || $KA_KEY == q ]] && return 0
            continue
        fi
        lines=${KA_TUI_LINES}; page=$((lines - 7)); ((page < 3)) && page=3
        ((offset > total - page)) && offset=$((total - page)); ((offset < 0)) && offset=0
        detail_w=$(ka_tui_field_width 34 12)
        ka_tui_box_top "$KA_I_LOG" 'Event Log' "$total events"
        printf '\033[K\n'
        local i time event detail result
        for ((i=offset; i<total && i<offset+page; i++)); do
            IFS=$'\t' read -r time event detail result <<<"${log_lines[$i]}"
            printf ' %-8s %-11s %-*s %s\033[K\n' "$time" "$event" \
                "$detail_w" "$(ka_tui_truncate "$detail" "$detail_w")" "$(ka_tui_truncate "$result" 12)"
        done
        printf '\033[K\n up/down scroll   PgUp/PgDn page   g first   G last   Esc back\033[K\n'
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in
            UP|k) ((offset > 0)) && offset=$((offset - 1)) ;;
            DOWN|j) ((offset + page < total)) && offset=$((offset + 1)) ;;
            PGUP) offset=$((offset - page)); ((offset < 0)) && offset=0 ;;
            PGDN) offset=$((offset + page));;
            g|HOME) offset=0 ;;
            G|END) offset=$((total - page)); ((offset < 0)) && offset=0 ;;
            ESC|q) return 0 ;;
        esac
    done
}

# Role: Run the detail control loop for one existing keep-alive until the user returns/deletes it.
ka_tui_detail() {
    local uuid=$1 key status type name
    ka_state_target_dir "$uuid"
    local state_file="$REPLY/state.tsv"
    while [[ -r $state_file ]]; do
        ka_tui_render_detail "$uuid" || return 0
        ka_tui_read_key 1 || continue
        key=$KA_KEY
        # KA_F_* were populated by the render above; no second parse of state.tsv.
        status=${KA_F_STATUS:-UNAVAILABLE}; type=${KA_F_TYPE-}; name=${KA_F_NAME-}
        case $key in
            ESC|q) return 0 ;;
            l|L) ka_tui_logs "$uuid" || true ;;
            d|D)
                if ka_tui_confirm_delete "$type / $name"; then
                    ka_tui_action DELETE "$uuid" || true
                    return 0
                fi
                ;;
            n|N) ka_tui_guard_action "$status" SEND_MAIN "$uuid" ;;
            s|S) ka_tui_guard_action "$status" SEND_SECONDARY "$uuid" ;;
            r|R) ka_tui_guard_action "$status" RESET_MAIN "$uuid" ;;
            p|P) ka_tui_guard_action "$status" TOGGLE_PAUSE "$uuid" ;;
            e) ka_tui_guard_action "$status" SEND_ENTER "$uuid" ;;
            E) ka_tui_guard_action "$status" SET_MODE "$uuid" ENTER_ONLY ;;
            c|C)
                if [[ $status != UNAVAILABLE ]]; then
                    ka_tui_run_wizard "$uuid" "$status" "$type" "$name" || true
                fi
                ;;
        esac
    done
}

# Role: Open the correct screen for the highlighted row, wizard for AVAILABLE and detail otherwise.
# Always succeeds: a cancelled wizard or failed action is normal navigation, and the client
# runs under `set -e`, where letting that status escape terminates the whole TUI.
ka_tui_open_row() {
    local i=$1
    ((i >= 0 && i < ${#KA_R_UUID[@]})) || return 0
    if [[ ${KA_R_STATUS[$i]} == AVAILABLE ]]; then
        ka_tui_run_wizard "${KA_R_UUID[$i]}" AVAILABLE "${KA_R_TYPE[$i]}" "${KA_R_NAME[$i]}" || true
    else
        ka_tui_detail "${KA_R_UUID[$i]}" || true
    fi
    return 0
}

# Role: Run one detail-screen action unless the target is UNAVAILABLE, absorbing failures.
# Daemon rejections are reported to the user as a toast, never as a client exit status.
ka_tui_guard_action() {
    local status=$1 command=$2 uuid=$3 value=${4-}
    [[ $status != UNAVAILABLE ]] || return 0
    ka_tui_action "$command" "$uuid" "$value" || true
    return 0
}

# Role: Run the attachable manager TUI; exiting this function never stops the daemon or timers.
ka_tui_main() {
    local response selected=0 offset=0 key n max_rows desired_uuid idx i
    response=$(ka_ipc_call PING '' 2>/dev/null || true)
    [[ $response == OK$'\t'* ]] || { ka_error "service unavailable: ${response#*$'\t'}"; return 1; }
    ka_ipc_call REFRESH '' >/dev/null 2>&1 || true
    ka_wizard_cleanup_stale
    ka_tui_enter || return

    local dirty=1 tick last_tick=''
    # Load once up front so the KA_R_* arrays exist even when the index is empty.
    ka_tui_load_index
    while true; do
        if ka_tui_index_changed; then
            desired_uuid=${KA_R_UUID[$selected]-}
            ka_tui_load_index
            n=${#KA_R_UUID[@]}
            if [[ -n $desired_uuid ]] && idx=$(ka_tui_find_uuid_index "$desired_uuid"); then selected=$idx; fi
            dirty=1
        fi
        n=${#KA_R_UUID[@]}
        ((n == 0)) && selected=0
        ((selected >= n && n > 0)) && selected=$((n - 1))

        max_rows=$((${KA_TUI_LINES:-24} - 9)); ((max_rows < 3)) && max_rows=3
        ((selected < offset)) && { offset=$selected; dirty=1; }
        ((selected >= offset + max_rows)) && { offset=$((selected - max_rows + 1)); dirty=1; }
        ((offset < 0)) && offset=0

        # The header carries a clock, so redraw at 1 Hz even when nothing else moved.
        # Everything else is event-driven: an idle manager no longer repaints 4x a second.
        printf -v tick '%(%H:%M:%S)T' -1
        if [[ $tick != "$last_tick" ]]; then
            dirty=1
            last_tick=$tick
            # Tell the daemon a client is watching so it keeps discovery responsive.
            # A redirect from printf is a builtin write, so this costs no fork.
            printf '%(%s)T\033[K\n' -1 >"$KA_CLIENT_PRESENCE_FILE" 2>/dev/null || true
        fi
        [[ -n ${KA_TUI_TOAST:-} ]] && dirty=1
        ((${KA_TUI_RESIZED:-0} == 1)) && dirty=1
        if ((dirty == 1)); then
            ka_tui_render_manager "$selected" "$offset"
            dirty=0
        fi

        if ! ka_tui_read_key 0.25; then continue; fi
        dirty=1
        key=$KA_KEY
        case $key in
            q|Q|ESC) return 0 ;;
            UP|k)
                if ((n > 0)); then selected=$((selected - 1)); ((selected < 0)) && selected=$((n - 1)); fi
                ;;
            DOWN|j)
                if ((n > 0)); then selected=$((selected + 1)); ((selected >= n)) && selected=0; fi
                ;;
            HOME) selected=0 ;;
            END) ((n > 0)) && selected=$((n - 1)) ;;
            PGUP) selected=$((selected - max_rows)); ((selected < 0)) && selected=0 ;;
            PGDN)
                selected=$((selected + max_rows))
                ((n > 0 && selected >= n)) && selected=$((n - 1))
                ((selected < 0)) && selected=0
                ;;
            [1-9])
                i=$((key - 1))
                if ((i < n)); then selected=$i; ka_tui_open_row "$selected"; fi
                ;;
            ENTER)
                if ((n > 0)); then ka_tui_open_row "$selected"; fi
                ;;
            r|R) ka_tui_action REFRESH '' || true ;;
        esac
    done
}
