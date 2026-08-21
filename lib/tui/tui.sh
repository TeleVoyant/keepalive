#!/usr/bin/env bash
# High-level manager, target detail, logs, and interactive client screens.

# Role: Map AI client names to stable sorting groups (Claude, Codex, Kimi, then others).
ka_tui_type_rank() {
    case $1 in Claude) printf 10;; Codex) printf 20;; Kimi) printf 30;; *) printf 40;; esac
}

# Role: Map target states to the agreed ACTIVE, PAUSED, UNAVAILABLE, AVAILABLE sort order.
ka_tui_status_rank() {
    case $1 in ACTIVE) printf 10;; PAUSED) printf 20;; UNAVAILABLE) printf 30;; AVAILABLE) printf 40;; *) printf 50;; esac
}

# Role: Load and sort the daemon's atomic index snapshot into TUI row arrays.
ka_tui_load_index() {
    declare -ga KA_R_UUID=() KA_R_TYPE=() KA_R_NAME=() KA_R_DIR=() KA_R_STATUS=()
    declare -ga KA_R_MAIN_REMAIN=() KA_R_MAIN_INTERVAL=() KA_R_SEC_ENABLED=() KA_R_SEC_REMAIN=()
    declare -ga KA_R_SEC_INTERVAL=() KA_R_MODE=() KA_R_NOTIFY=() KA_R_LAST=() KA_R_REASON=()
    [[ -r $KA_INDEX_FILE ]] || return 0

    local tmp uuid type name directory status mr mi se sr si mode notify last reason tr srank
    tmp=$(mktemp "$KA_RUNTIME_DIR/index-sort.XXXXXX") || return 1
    while IFS=$'\t' read -r uuid type name directory status mr mi se sr si mode notify last reason; do
        [[ -n $uuid ]] || continue
        tr=$(ka_tui_type_rank "$type")
        srank=$(ka_tui_status_rank "$status")
        printf '%03d\t%s\t%03d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$tr" "${type,,}" "$srank" "$uuid" "$type" "$name" "$directory" "$status" "${mr:-0}" "${mi:-0}" \
            "${se:-0}" "${sr:-0}" "${si:-0}" "$mode" "${notify:-0}" "$last" "$reason" >>"$tmp"
    done <"$KA_INDEX_FILE"

    while IFS=$'\t' read -r _ _ _ uuid type name directory status mr mi se sr si mode notify last reason; do
        KA_R_UUID+=("$uuid") KA_R_TYPE+=("$type") KA_R_NAME+=("$name") KA_R_DIR+=("$directory")
        KA_R_STATUS+=("$status") KA_R_MAIN_REMAIN+=("$mr") KA_R_MAIN_INTERVAL+=("$mi")
        KA_R_SEC_ENABLED+=("$se") KA_R_SEC_REMAIN+=("$sr") KA_R_SEC_INTERVAL+=("$si")
        KA_R_MODE+=("$mode") KA_R_NOTIFY+=("$notify") KA_R_LAST+=("$last") KA_R_REASON+=("$reason")
    done < <(sort -t $'\t' -k1,1n -k2,2f -k3,3n -k6,6f "$tmp")
    rm -f -- "$tmp"
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

# Role: Render one manager row in full-width table form with compact timer depletion bar.
ka_tui_render_row_full() {
    local i=$1 selected=$2 number=$3 marker=' ' type name status mr mi se sr time sec_text
    ((i == selected)) && marker='❯'
    type=${KA_R_TYPE[$i]}; name=${KA_R_NAME[$i]}; status=${KA_R_STATUS[$i]}
    mr=${KA_R_MAIN_REMAIN[$i]}; mi=${KA_R_MAIN_INTERVAL[$i]}; se=${KA_R_SEC_ENABLED[$i]}; sr=${KA_R_SEC_REMAIN[$i]}
    name=$(ka_tui_truncate "$name" 25)
    printf ' %s %2d ' "$marker" "$number"
    [[ -n $KA_I_AI ]] && printf '%s ' "$KA_I_AI"
    printf '%-10s %-25s ' "$type" "$name"
    ka_tui_status "$status"
    printf '%*s' "$((14 - ${#status}))" ''
    if [[ $status == ACTIVE || $status == PAUSED ]]; then
        ka_tui_progress "$mr" "$mi" 10
        time=$(ka_format_duration "$mr")
        printf ' %-8s ' "$time"
        if [[ $se == 1 ]]; then sec_text=$(ka_format_duration "$sr"); printf '%-8s' "$sec_text"; else printf '%-8s' '—'; fi
    else
        printf '%-20s %-8s' '—' '—'
    fi
    printf '\n'
}

# Role: Render one manager row in narrow stacked form when terminal width is constrained.
ka_tui_render_row_compact() {
    local i=$1 selected=$2 number=$3 marker=' ' status mr mi se sr
    ((i == selected)) && marker='❯'
    status=${KA_R_STATUS[$i]}; mr=${KA_R_MAIN_REMAIN[$i]}; mi=${KA_R_MAIN_INTERVAL[$i]}; se=${KA_R_SEC_ENABLED[$i]}; sr=${KA_R_SEC_REMAIN[$i]}
    printf ' %s %2d %-10s / %s\n' "$marker" "$number" "${KA_R_TYPE[$i]}" "$(ka_tui_truncate "${KA_R_NAME[$i]}" 30)"
    printf '      '; ka_tui_status "$status"
    if [[ $status == ACTIVE || $status == PAUSED ]]; then
        printf '   '; ka_tui_progress "$mr" "$mi" 10; printf ' %s' "$(ka_format_duration "$mr")"
        [[ $se == 1 ]] && printf '   S %s' "$(ka_format_duration "$sr")"
    fi
    printf '\n'
}

# Role: Render the canonical manager overview while adapting to terminal dimensions.
ka_tui_render_manager() {
    local selected=$1 offset=$2 cols lines max_rows end i n active paused available unavailable now
    cols=$(ka_tui_cols); lines=$(ka_tui_lines)
    ka_tui_frame_begin
    if ((cols < 52 || lines < 14)); then
        printf 'Keep Alive Manager\n\nTerminal too small. Resize to at least 52x14.\n'
        ka_tui_frame_end
        return
    fi
    n=${#KA_R_UUID[@]}
    active=$(ka_tui_state_count ACTIVE); paused=$(ka_tui_state_count PAUSED)
    available=$(ka_tui_state_count AVAILABLE); unavailable=$(ka_tui_state_count UNAVAILABLE)
    now=$(ka_now_hms)
    printf '╭─ '; ka_icon_label "$KA_I_AI" 'Keep Alive Manager'; printf ' ───────────────────────── %s ─╮\n' "$now"
    printf '│ '; ka_icon_label "$KA_I_SERVICE" 'service online'; printf '   %d AI sessions   %d active   %d paused   %d available   %d unavailable\n' "$n" "$active" "$paused" "$available" "$unavailable"
    printf '╰──────────────────────────────────────────────────────────────────────────────╯\n\n'

    max_rows=$((lines - 9)); ((max_rows < 3)) && max_rows=3
    end=$((offset + max_rows)); ((end > n)) && end=$n
    if ((cols >= 100)); then
        printf '    TYPE       SESSION                    KEEP-ALIVE          MAIN                NUDGE\n'
        printf '  ───────────────────────────────────────────────────────────────────────────────\n'
        for ((i=offset; i<end; i++)); do ka_tui_render_row_full "$i" "$selected" "$((i + 1))"; done
    else
        for ((i=offset; i<end; i++)); do ka_tui_render_row_compact "$i" "$selected" "$((i + 1))"; done
    fi
    printf '\n  ↑/↓ or j/k navigate    1–9 select    Enter open    r refresh    q quit\n'
    ka_tui_render_toast
    ka_tui_frame_end
}

# Role: Submit one simple target action and convert daemon response into a transient toast.
ka_tui_action() {
    local command=$1 uuid=$2 response
    response=$(ka_ipc_call "$command" "$uuid" 2>/dev/null || true)
    if [[ $response == OK$'\t'* ]]; then ka_tui_toast "${response#*$'\t'}"; return 0; fi
    ka_tui_toast "${response#*$'\t'}"
    return 1
}

# Role: Confirm destructive deletion without allowing a single accidental keypress to remove state.
ka_tui_confirm_delete() {
    local name=$1 key
    while true; do
        ka_tui_frame_begin
        printf '╭─ %s Delete Keep Alive ─╮\n' "$KA_I_DELETE"
        printf '│ Delete keep-alive for %s?\n' "$name"
        printf '│ This removes only manager state and this target\x27s runtime event history.\n'
        printf '│ The AI process and Konsole tab are never terminated.\n'
        printf '│\n│ y delete     n/Esc cancel\n╰─────────────────────────╯\n'
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in y|Y) return 0;; n|N|ESC) return 1;; esac
    done
}

# Role: Render recent per-target events in the detailed keep-alive screen.
ka_tui_render_recent_events() {
    local uuid=$1 max=${2:-6} time event detail result
    printf '├─ '; ka_icon_label "$KA_I_LOG" 'Recent events'; printf ' ──────────────────────────────────────────────────────────────┤\n'
    while IFS=$'\t' read -r time event detail result; do
        printf '│  %-8s %-11s %-40s %-12s\n' "$time" "$event" "$(ka_tui_truncate "$detail" 40)" "$result"
    done < <(ka_log_tail "$uuid" "$max")
}

# Role: Render one existing keep-alive target detail view from atomic persisted state.
ka_tui_render_detail() {
    local uuid=$1 type name directory status mode notify mr mi idx se sr si secondary reason last cols
    type=$(ka_state_read_field "$uuid" type); name=$(ka_state_read_field "$uuid" name); directory=$(ka_state_read_field "$uuid" directory)
    status=$(ka_state_read_field "$uuid" status); mode=$(ka_state_read_field "$uuid" mode); notify=$(ka_state_read_field "$uuid" notifications)
    mr=$(ka_state_read_field "$uuid" main_remaining); mi=$(ka_state_read_field "$uuid" main_interval); idx=$(ka_state_read_field "$uuid" main_index)
    se=$(ka_state_read_field "$uuid" secondary_enabled); sr=$(ka_state_read_field "$uuid" secondary_remaining); si=$(ka_state_read_field "$uuid" secondary_interval)
    reason=$(ka_state_read_field "$uuid" reason || true); last=$(ka_state_read_field "$uuid" last_seen || true)
    secondary=$(cat "$(ka_state_target_dir "$uuid")/secondary_message" 2>/dev/null || true)
    cols=$(ka_tui_cols)

    ka_tui_frame_begin
    printf '╭─ '; ka_icon_label "$KA_I_AI" "Keep Alive · $type / $name"; printf ' ─────────────────────────── %s ─╮\n' "$(ka_now_hms)"
    printf '│\n│  Status          '; ka_tui_status "$status"; printf '\n'
    printf '│  '; ka_icon_label "$KA_I_TERM" 'Target'; printf '          %s\n' "$type"
    printf '│  '; ka_icon_label "$KA_I_DIR" 'Directory'; printf '       %s\n' "$(ka_tui_truncate "$directory" $((cols - 24)))"
    printf '│  '; ka_icon_label "$KA_I_SESSION" 'Session'; printf '         %s\n' "$(ka_tui_truncate "$uuid" 28)"
    printf '│\n│  '; ka_icon_label "$KA_I_ENTER" 'Delivery'; printf '        %s\n' "$([[ $mode == MESSAGE_ENTER ]] && printf 'MESSAGE + ENTER' || printf 'ENTER ONLY')"
    printf '│  '; ka_icon_label "$KA_I_NOTIFY" 'Notification'; printf '    %s\n' "$([[ $notify == 1 ]] && printf ON || printf OFF)"

    if [[ $status == UNAVAILABLE ]]; then
        printf '│\n│  Last seen        %s\n│  Reason           %s\n' "$last" "$reason"
        printf '│\n│  Timers are frozen. This record will remain until you delete it.\n'
    fi

    printf '├─ '; ka_icon_label "$KA_I_TIMER" 'Timers'; printf ' ──────────────────────────────────────────────────────────────────────┤\n│\n'
    printf '│  MAIN       '; ka_tui_progress "$mr" "$mi" 16; printf '  %-10s   interval %s%s\n' "$(ka_format_duration "$mr")" "$(ka_format_duration "$mi")" "$([[ $status == PAUSED || $status == UNAVAILABLE ]] && printf ' · frozen')"
    if [[ $se == 1 ]]; then
        printf '│  SECONDARY  '; ka_tui_progress "$sr" "$si" 16; printf '  %-10s   interval %s%s\n' "$(ka_format_duration "$sr")" "$(ka_format_duration "$si")" "$([[ $status == PAUSED || $status == UNAVAILABLE ]] && printf ' · frozen')"
        printf '│  Prompt     %s\n' "$(ka_tui_truncate "$secondary" $((cols - 15)))"
    else
        printf '│  SECONDARY  disabled\n'
    fi

    printf '├─ '; ka_icon_label "$KA_I_MESSAGE" 'Message rotation'; printf ' ───────────────────────────────────────────────────────────────┤\n'
    local dir file number=0 count current_marker
    dir=$(ka_state_target_dir "$uuid"); count=$(ka_state_message_count "$uuid")
    shopt -s nullglob
    for file in "$dir/messages"/[0-9][0-9][0-9]; do
        ((number += 1)); current_marker=' '
        ((number - 1 == idx)) && current_marker='→'
        printf '│   %s %2d. %s\n' "$current_marker" "$number" "$(ka_tui_truncate "$(cat "$file")" $((cols - 12)))"
    done
    shopt -u nullglob
    [[ $mode == ENTER_ONLY ]] && printf '│   Enter-only mode does not consume the queued message.\n'
    ka_tui_render_recent_events "$uuid" 5
    printf '╰──────────────────────────────────────────────────────────────────────────────╯\n\n'
    if [[ $status == UNAVAILABLE ]]; then
        printf '  l full logs       d delete       Esc back\n'
    else
        printf '  n main now   s secondary now   r reset main   p pause/resume   e delivery mode\n'
        printf '  c configure  l full logs       d delete       Esc back\n'
    fi
    ka_tui_render_toast
    ka_tui_frame_end
}

# Role: Provide a scrollable full per-target event-log viewer with vim-like navigation.
ka_tui_logs() {
    local uuid=$1 offset=0 key lines page total
    local -a log_lines=()
    while true; do
        mapfile -t log_lines < <(ka_log_all "$uuid")
        total=${#log_lines[@]}
        lines=$(ka_tui_lines); page=$((lines - 7)); ((page < 3)) && page=3
        ((offset > total - page)) && offset=$((total - page)); ((offset < 0)) && offset=0
        ka_tui_frame_begin
        printf '╭─ '; ka_icon_label "$KA_I_LOG" 'Event Log'; printf ' ─ %s events ─╮\n\n' "$total"
        local i time event detail result
        for ((i=offset; i<total && i<offset+page; i++)); do
            IFS=$'\t' read -r time event detail result <<<"${log_lines[$i]}"
            printf ' %-8s %-11s %-46s %-12s\n' "$time" "$event" "$(ka_tui_truncate "$detail" 46)" "$result"
        done
        printf '\n ↑/↓ scroll   PgUp/PgDn page   g first   G last   Esc back\n'
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
    local uuid=$1 key status type name response
    while [[ -r $(ka_state_target_dir "$uuid")/state.tsv ]]; do
        ka_tui_render_detail "$uuid"
        ka_tui_read_key 1 || continue
        key=$KA_KEY
        status=$(ka_state_read_field "$uuid" status || printf UNAVAILABLE)
        type=$(ka_state_read_field "$uuid" type || true); name=$(ka_state_read_field "$uuid" name || true)
        case $key in
            ESC|q) return 0 ;;
            l|L) ka_tui_logs "$uuid" ;;
            d|D)
                if ka_tui_confirm_delete "$type / $name"; then ka_tui_action DELETE "$uuid"; return 0; fi
                ;;
            n|N) [[ $status != UNAVAILABLE ]] && ka_tui_action SEND_MAIN "$uuid" ;;
            s|S) [[ $status != UNAVAILABLE ]] && ka_tui_action SEND_SECONDARY "$uuid" ;;
            r|R) [[ $status != UNAVAILABLE ]] && ka_tui_action RESET_MAIN "$uuid" ;;
            p|P) [[ $status != UNAVAILABLE ]] && ka_tui_action TOGGLE_PAUSE "$uuid" ;;
            e|E) [[ $status != UNAVAILABLE ]] && ka_tui_action TOGGLE_MODE "$uuid" ;;
            c|C) [[ $status != UNAVAILABLE ]] && ka_tui_run_wizard "$uuid" "$status" "$type" "$name" ;;
        esac
    done
}

# Role: Run the attachable manager TUI; exiting this function never stops the daemon or timers.
ka_tui_main() {
    local response selected=0 offset=0 key n lines max_rows desired_uuid idx i last_refresh=0 now
    response=$(ka_ipc_call PING '' 2>/dev/null || true)
    [[ $response == OK$'\t'* ]] || { ka_error "service unavailable: ${response#*$'\t'}"; return 1; }
    ka_ipc_call REFRESH '' >/dev/null 2>&1 || true
    ka_tui_enter || return

    while true; do
        desired_uuid=${KA_R_UUID[$selected]-}
        ka_tui_load_index
        n=${#KA_R_UUID[@]}
        if [[ -n $desired_uuid ]] && idx=$(ka_tui_find_uuid_index "$desired_uuid"); then selected=$idx; fi
        ((n == 0)) && selected=0
        ((selected >= n && n > 0)) && selected=$((n - 1))

        lines=$(ka_tui_lines); max_rows=$((lines - 9)); ((max_rows < 3)) && max_rows=3
        ((selected < offset)) && offset=$selected
        ((selected >= offset + max_rows)) && offset=$((selected - max_rows + 1))
        ka_tui_render_manager "$selected" "$offset"

        if ! ka_tui_read_key 0.25; then continue; fi
        key=$KA_KEY
        case $key in
            q|Q|ESC) return 0 ;;
            UP|k)
                if ((n > 0)); then selected=$((selected - 1)); ((selected < 0)) && selected=$((n - 1)); fi
                ;;
            DOWN|j)
                if ((n > 0)); then selected=$((selected + 1)); ((selected >= n)) && selected=0; fi
                ;;
            [1-9])
                i=$((key - 1))
                if ((i < n)); then
                    selected=$i
                    if [[ ${KA_R_STATUS[$selected]} == AVAILABLE ]]; then
                        ka_tui_run_wizard "${KA_R_UUID[$selected]}" AVAILABLE "${KA_R_TYPE[$selected]}" "${KA_R_NAME[$selected]}"
                    else
                        ka_tui_detail "${KA_R_UUID[$selected]}"
                    fi
                fi
                ;;
            ENTER)
                if ((n > 0)); then
                    if [[ ${KA_R_STATUS[$selected]} == AVAILABLE ]]; then
                        ka_tui_run_wizard "${KA_R_UUID[$selected]}" AVAILABLE "${KA_R_TYPE[$selected]}" "${KA_R_NAME[$selected]}"
                    else
                        ka_tui_detail "${KA_R_UUID[$selected]}"
                    fi
                fi
                ;;
            r|R)
                ka_tui_action REFRESH ''
                ;;
        esac
    done
}
