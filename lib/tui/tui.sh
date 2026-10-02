#!/usr/bin/env bash
# High-level manager, target detail, logs, and interactive client screens.

# Row order from the last index sort and the per-UUID type/name/status keys it was computed
# from; ka_tui_load_index re-sorts only when those keys change. Assigned here, not merely
# declared: an unassigned associative array is still unbound under `set -u`.
declare -ga KA_TUI_SORT_ORDER=()
declare -gA KA_TUI_SORT_KEYS=()

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
    declare -ga KA_R_BACKEND=() KA_R_NEXT_MAIN=() KA_R_NEXT_SECONDARY=()
    declare -ga KA_R_LAST_DELIVERY_TIME=() KA_R_LAST_DELIVERY_EVENT=()
    declare -ga KA_R_LAST_DELIVERY_RESULT=() KA_R_LAST_DELIVERY_DETAIL=()
    [[ -r $KA_INDEX_FILE ]] || return 0

    # The row order depends only on each row's UUID, type, name, and status. A watched
    # index changes every second because countdowns tick, so the external sort ran once a
    # second for an order that had not moved; it now runs only when one of those keys did.
    # The comparison is per UUID, so the same rows published in another order do not
    # count as a change. Rows are parsed from this one read, so the order and the rows
    # always describe the same publication.
    local sorted rest line uuid resort=0
    local -a lines=()
    local -A row_by_uuid=() keys=()
    mapfile -t lines <"$KA_INDEX_FILE" || true
    for line in "${lines[@]}"; do
        [[ -n $line ]] || continue
        ka_tui_split_tsv "$line"
        [[ -n ${KA_TSV[0]-} ]] || continue
        keys[${KA_TSV[0]}]="${KA_TSV[1]-}"$'\t'"${KA_TSV[2]-}"$'\t'"${KA_TSV[4]-}"
        row_by_uuid[${KA_TSV[0]}]=$line
    done
    if ((${#keys[@]} != ${#KA_TUI_SORT_KEYS[@]})); then
        resort=1
    else
        for uuid in "${!keys[@]}"; do
            if [[ -z ${KA_TUI_SORT_KEYS[$uuid]+x} || ${KA_TUI_SORT_KEYS[$uuid]} != "${keys[$uuid]}" ]]; then
                resort=1
                break
            fi
        done
    fi
    if ((resort == 1)); then
        KA_TUI_SORT_ORDER=()
        while IFS= read -r sorted; do
            # Drop the three synthetic sort keys; the UUID is the next column.
            rest=${sorted#*$'\t'}; rest=${rest#*$'\t'}; rest=${rest#*$'\t'}
            KA_TUI_SORT_ORDER+=("${rest%%$'\t'*}")
        done < <(printf '%s\n' "${lines[@]}" | ka_tui_sort_index_rows)
        KA_TUI_SORT_KEYS=()
        for uuid in "${!keys[@]}"; do KA_TUI_SORT_KEYS[$uuid]=${keys[$uuid]}; done
    fi

    for uuid in "${KA_TUI_SORT_ORDER[@]}"; do
        [[ -n ${row_by_uuid[$uuid]+x} ]] || continue
        ka_tui_split_tsv "${row_by_uuid[$uuid]}"
        unset 'row_by_uuid[$uuid]'
        KA_R_UUID+=("${KA_TSV[0]-}") KA_R_TYPE+=("${KA_TSV[1]-}") KA_R_NAME+=("${KA_TSV[2]-}")
        KA_R_DIR+=("${KA_TSV[3]-}") KA_R_STATUS+=("${KA_TSV[4]-}")
        KA_R_MAIN_REMAIN+=("${KA_TSV[5]:-0}") KA_R_MAIN_INTERVAL+=("${KA_TSV[6]:-0}")
        KA_R_SEC_ENABLED+=("${KA_TSV[7]:-0}") KA_R_SEC_REMAIN+=("${KA_TSV[8]:-0}")
        KA_R_SEC_INTERVAL+=("${KA_TSV[9]:-0}") KA_R_MODE+=("${KA_TSV[10]-}")
        KA_R_NOTIFY+=("${KA_TSV[11]:-0}") KA_R_LAST+=("${KA_TSV[12]-}") KA_R_REASON+=("${KA_TSV[13]-}")
        KA_R_BACKEND+=("${KA_TSV[14]:-konsole}")
        KA_R_NEXT_MAIN+=("${KA_TSV[15]-}") KA_R_NEXT_SECONDARY+=("${KA_TSV[16]-}")
        KA_R_LAST_DELIVERY_TIME+=("${KA_TSV[17]-}") KA_R_LAST_DELIVERY_EVENT+=("${KA_TSV[18]-}")
        KA_R_LAST_DELIVERY_RESULT+=("${KA_TSV[19]-}") KA_R_LAST_DELIVERY_DETAIL+=("${KA_TSV[20]-}")
    done
}

# Role: Emit stdin index rows prefixed with family/type/state sort keys, sorted.
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
    done | sort -t $'\t' -k1,1n -k2,2f -k3,3n -k6,6f
}

# Role: Read one target checkpoint once into KA_F_* fields for detail rendering.
# The previous per-field accessor reparsed state.tsv in a subshell for every value,
# costing roughly two dozen forks and file scans per detail frame.
ka_tui_load_target_fields() {
    local uuid=$1 file line key value
    KA_F_BACKEND='konsole' KA_F_TYPE='' KA_F_NAME='' KA_F_DIR='' KA_F_STATUS='' KA_F_MODE='' KA_F_NOTIFY=''
    KA_F_MAIN_REMAIN=0 KA_F_MAIN_INTERVAL=0 KA_F_MAIN_INDEX=0
    KA_F_SEC_ENABLED=0 KA_F_SEC_REMAIN=0 KA_F_SEC_INTERVAL=0 KA_F_SEC_DONE=0
    KA_F_SEC_MESSAGE_FILE='secondary_message'
    KA_F_LAST='' KA_F_REASON=''
    KA_F_LAST_DELIVERY_TIME='' KA_F_LAST_DELIVERY_EVENT=''
    KA_F_LAST_DELIVERY_RESULT='' KA_F_LAST_DELIVERY_DETAIL=''
    KA_F_NEXT_MAIN='' KA_F_NEXT_SECONDARY=''
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
            backend) KA_F_BACKEND=$value ;;
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
            secondary_message_file)
                if [[ $value =~ ^secondary_message\.[0-9]+\.[0-9]+$ ]]; then
                    KA_F_SEC_MESSAGE_FILE=$value
                else
                    KA_F_SEC_MESSAGE_FILE=''
                fi
                ;;
            last_seen) KA_F_LAST=$value ;;
            reason) KA_F_REASON=$value ;;
            last_delivery_time) KA_F_LAST_DELIVERY_TIME=$value ;;
            last_delivery_event) KA_F_LAST_DELIVERY_EVENT=$value ;;
            last_delivery_result) KA_F_LAST_DELIVERY_RESULT=$value ;;
            last_delivery_detail) KA_F_LAST_DELIVERY_DETAIL=$value ;;
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
    ka_tui_row_name_width_set
    printf '%d' "$REPLY"
}

# Role: Put the manager's session-name column width for the live terminal width in REPLY.
ka_tui_row_name_width_set() {
    local width=$((${KA_TUI_COLS:-80} - 65))
    ((width < 16)) && width=16
    ((width > 48)) && width=48
    REPLY=$width
}

# Role: Render one manager row in full-width table form with compact timer depletion bar.
ka_tui_render_row_full() {
    local i=$1 selected=$2 number=$3 name_w=$4 marker=' ' type name status mr mi se sr pad
    ((i == selected)) && marker=$KA_G_SEL
    type=${KA_R_TYPE[$i]}; status=${KA_R_STATUS[$i]}
    mr=${KA_R_MAIN_REMAIN[$i]}; mi=${KA_R_MAIN_INTERVAL[$i]}
    se=${KA_R_SEC_ENABLED[$i]}; sr=${KA_R_SEC_REMAIN[$i]}
    # Every value below comes from a REPLY helper: rows are redrawn once a second, and a
    # captured printing helper forked once per field per row.
    ka_tui_truncate_set "${KA_R_NAME[$i]}" "$name_w"; name=$REPLY
    ka_tui_truncate_set "$type" 10; type=$REPLY
    printf ' %s %2d ' "$marker" "$number"
    [[ -n $KA_I_AI ]] && printf '%s ' "$KA_I_AI"
    printf '%-10s %-*s ' "$type" "$name_w" "$name"
    ka_tui_status "$status"
    # Pad from the rendered cell count, not the bare word: the icon adds two cells and
    # used to shift every following column between --no-icons and icon mode.
    ka_tui_status_width_set "$status"
    pad=$((14 - REPLY))
    ((pad < 1)) && pad=1
    printf '%*s' "$pad" ''
    if [[ $status == ACTIVE || $status == PAUSED ]]; then
        ka_tui_progress "$mr" "$mi" 10
        ka_format_duration_set "$mr"
        printf ' %-8s ' "$REPLY"
        # Last column: no padding, so rows carry no trailing whitespace.
        if [[ $se == 1 ]]; then ka_format_duration_set "$sr"; printf '%s' "$REPLY"; else printf '%s' "$KA_G_NONE"; fi
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
    local type name
    ka_tui_field_width_set 22 12; name_w=$REPLY
    ka_tui_truncate_set "${KA_R_TYPE[$i]}" 10; type=$REPLY
    ka_tui_truncate_set "${KA_R_NAME[$i]}" "$name_w"; name=$REPLY
    printf ' %s %2d %-10s / %s\033[K\n' "$marker" "$number" "$type" "$name"
    printf '      '; ka_tui_status "$status"
    if [[ $status == ACTIVE || $status == PAUSED ]]; then
        printf '   '; ka_tui_progress "$mr" "$mi" 10
        ka_format_duration_set "$mr"; printf ' %s' "$REPLY"
        if [[ $se == 1 ]]; then ka_format_duration_set "$sr"; printf '   S %s' "$REPLY"; fi
    fi
    printf '\033[K\n'
}

# Role: Draw the manager header as a colored segment bar, falling back to the plain box.
# The bar needs color; --no-color, NO_COLOR, and a too-narrow terminal all take the box
# path, so every legacy presentation mode still renders a complete, readable header.
ka_tui_render_manager_header() {
    local n=$1 active=$2 paused=$3 available=$4 unavailable=$5 summary now
    printf -v now '%(%H:%M:%S)T' -1
    if ka_tui_bar_supported; then
        ka_tui_bar_begin
        ka_icon_label_set "$KA_I_AI" 'Keep Alive'
        ka_tui_bar_add 4 7 "$REPLY" 1
        ka_icon_label_set "$KA_I_SERVICE" 'online'
        ka_tui_bar_add 2 0 "$REPLY"
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
    # One counting pass in the current shell; four captured counters forked four times.
    local status
    active=0; paused=0; available=0; unavailable=0
    for status in "${KA_R_STATUS[@]}"; do
        case $status in
            ACTIVE) ((active += 1)) ;;
            PAUSED) ((paused += 1)) ;;
            AVAILABLE) ((available += 1)) ;;
            UNAVAILABLE) ((unavailable += 1)) ;;
        esac
    done

    ka_tui_render_manager_header "$n" "$active" "$paused" "$available" "$unavailable"

    max_rows=$((lines - 9)); ((max_rows < 3)) && max_rows=3
    end=$((offset + max_rows)); ((end > n)) && end=$n
    if ((cols >= 92)); then
        local name_w
        ka_tui_row_name_width_set; name_w=$REPLY
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
    if [[ $response == OK$'\t'* ]]; then
        ka_tui_toast "${response#*$'\t'}"
        ka_tui_detail_cache_invalidate
        return 0
    fi
    ka_tui_toast "${response#*$'\t'}"
    ka_tui_detail_cache_invalidate
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
        printf '%s The AI process and terminal session are never terminated.\033[K\n' "$KA_G_V"
        printf '%s\033[K\n%s y delete     n/Esc cancel\033[K\n' "$KA_G_V" "$KA_G_V"
        ka_tui_box_bottom
        ka_tui_frame_end
        ka_tui_read_key 60 || continue
        key=$KA_KEY
        case $key in y|Y) return 0;; n|N|ESC) return 1;; esac
    done
}

declare -ga KA_TUI_DETAIL_MESSAGES=() KA_TUI_DETAIL_EVENTS=()
declare -g KA_TUI_DETAIL_UUID='' KA_TUI_DETAIL_CACHE_MARKER=''
declare -g KA_TUI_DETAIL_CACHE_VALID=0 KA_TUI_DETAIL_SECONDARY=''

# Role: Invalidate detail data after an action so the next frame reloads durable text/log data.
ka_tui_detail_cache_invalidate() {
    KA_TUI_DETAIL_CACHE_VALID=0
}

# Role: Create a private client-only marker used for fork-free state-generation checks.
ka_tui_detail_cache_begin() {
    local uuid=$1 marker
    KA_TUI_DETAIL_UUID=$uuid
    KA_TUI_DETAIL_CACHE_VALID=0
    KA_TUI_DETAIL_CACHE_MARKER=''
    while :; do
        marker="$KA_RUNTIME_DIR/.detail-cache.$$.${RANDOM}"
        [[ ! -e $marker && ! -L $marker ]] || continue
        if { : >"$marker"; } 2>/dev/null; then
            KA_TUI_DETAIL_CACHE_MARKER=$marker
            return 0
        fi
        return 1
    done
}

# Role: Remove the detail marker when leaving the session without touching daemon state.
ka_tui_detail_cache_end() {
    if [[ -n ${KA_TUI_DETAIL_CACHE_MARKER:-} ]]; then
        rm -f -- "$KA_TUI_DETAIL_CACHE_MARKER" 2>/dev/null || true
    fi
    KA_TUI_DETAIL_CACHE_MARKER=''
    KA_TUI_DETAIL_CACHE_VALID=0
}

# Role: Report whether persisted target state changed since the cached detail data was read.
ka_tui_detail_cache_needs_reload() {
    local uuid=$1 state_file log_file
    [[ ${KA_TUI_DETAIL_CACHE_VALID:-0} == 1 ]] || return 0
    ka_state_target_dir "$uuid"
    state_file="$REPLY/state.tsv"
    [[ -r $state_file && -n ${KA_TUI_DETAIL_CACHE_MARKER:-} \
        && $state_file -nt $KA_TUI_DETAIL_CACHE_MARKER ]] && return 0
    # Some events (suspend and clock-gap TIMER entries) reach only the log, never the
    # checkpoint; the cached recent-event tail must follow the log too.
    ka_safe_id "$uuid"
    log_file="$KA_LOGS_DIR/$REPLY.log"
    [[ -r $log_file && -n ${KA_TUI_DETAIL_CACHE_MARKER:-} \
        && $log_file -nt $KA_TUI_DETAIL_CACHE_MARKER ]] && return 0
    return 1
}

# Role: Load durable detail text/log data once and refresh it only after an action or save.
ka_tui_detail_cache_load() {
    local uuid=$1 target_dir file line text log_file safe_uuid
    local -a trimmed=()
    ka_tui_detail_cache_needs_reload "$uuid" || return 0
    ka_tui_load_target_fields "$uuid" || return 1
    ka_state_target_dir "$uuid"
    target_dir=$REPLY
    KA_TUI_DETAIL_SECONDARY=''
    if [[ -n $KA_F_SEC_MESSAGE_FILE && -r $target_dir/$KA_F_SEC_MESSAGE_FILE ]]; then
        IFS= read -r KA_TUI_DETAIL_SECONDARY <"$target_dir/$KA_F_SEC_MESSAGE_FILE" || true
    fi
    KA_TUI_DETAIL_MESSAGES=()
    shopt -s nullglob
    local -a message_files=("$target_dir/messages"/[0-9][0-9][0-9])
    shopt -u nullglob
    for file in "${message_files[@]}"; do
        [[ -f $file && ! -L $file && -O $file && -r $file ]] || continue
        text=''
        IFS= read -r text <"$file" || true
        KA_TUI_DETAIL_MESSAGES+=("$text")
    done
    KA_TUI_DETAIL_EVENTS=()
    ka_safe_id "$uuid"; safe_uuid=$REPLY
    log_file="$KA_LOGS_DIR/$safe_uuid.log"
    if [[ -f $log_file && ! -L $log_file && -O $log_file && -r $log_file ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            KA_TUI_DETAIL_EVENTS+=("$line")
            if ((${#KA_TUI_DETAIL_EVENTS[@]} > 5)); then
                trimmed=("${KA_TUI_DETAIL_EVENTS[@]:1}")
                KA_TUI_DETAIL_EVENTS=("${trimmed[@]}")
            fi
        done <"$log_file"
    fi
    printf '%s\n' "$uuid" >"$KA_TUI_DETAIL_CACHE_MARKER"
    KA_TUI_DETAIL_CACHE_VALID=1
}

# Role: Overlay live countdown/index fields while cached message text remains untouched.
ka_tui_detail_overlay_index() {
    local uuid=$1 i
    for i in "${!KA_R_UUID[@]}"; do
        [[ ${KA_R_UUID[$i]} == "$uuid" ]] || continue
        KA_F_STATUS=${KA_R_STATUS[$i]}
        KA_F_MAIN_REMAIN=${KA_R_MAIN_REMAIN[$i]}; KA_F_MAIN_INTERVAL=${KA_R_MAIN_INTERVAL[$i]}
        KA_F_SEC_ENABLED=${KA_R_SEC_ENABLED[$i]}; KA_F_SEC_REMAIN=${KA_R_SEC_REMAIN[$i]}
        KA_F_SEC_INTERVAL=${KA_R_SEC_INTERVAL[$i]}
        KA_F_LAST=${KA_R_LAST[$i]}; KA_F_REASON=${KA_R_REASON[$i]}
        KA_F_LAST_DELIVERY_TIME=${KA_R_LAST_DELIVERY_TIME[$i]-}
        KA_F_LAST_DELIVERY_EVENT=${KA_R_LAST_DELIVERY_EVENT[$i]-}
        KA_F_LAST_DELIVERY_RESULT=${KA_R_LAST_DELIVERY_RESULT[$i]-}
        KA_F_LAST_DELIVERY_DETAIL=${KA_R_LAST_DELIVERY_DETAIL[$i]-}
        KA_F_NEXT_MAIN=${KA_R_NEXT_MAIN[$i]-}; KA_F_NEXT_SECONDARY=${KA_R_NEXT_SECONDARY[$i]-}
        return 0
    done
    return 1
}

# Role: Render recent per-target events in the detailed keep-alive screen.
ka_tui_render_recent_events() {
    local max=${2:-6} time event detail result detail_w i start
    ka_tui_box_mid "$KA_I_LOG" 'Recent events'
    ka_tui_field_width_set 38 12; detail_w=$REPLY
    start=0
    ((${#KA_TUI_DETAIL_EVENTS[@]} > max)) && start=$(( ${#KA_TUI_DETAIL_EVENTS[@]} - max ))
    for ((i=start; i<${#KA_TUI_DETAIL_EVENTS[@]}; i++)); do
        IFS=$'\t' read -r time event detail result <<<"${KA_TUI_DETAIL_EVENTS[$i]}"
        ka_tui_truncate_set "$detail" "$detail_w"; detail=$REPLY
        ka_tui_truncate_set "$result" 12; result=$REPLY
        printf '%s  %-8s %-11s %-*s %s\033[K\n' "$KA_G_V" "$time" "$event" \
            "$detail_w" "$detail" "$result"
    done
}

# Role: Draw the detail header as a colored segment bar, falling back to the plain box.
# Reads the KA_F_* fields loaded by the caller; adds no extra checkpoint parse.
ka_tui_render_detail_header() {
    local title now duration label
    ka_tui_truncate_set "$KA_F_TYPE / $KA_F_NAME" 32; label=$REPLY
    ka_icon_label_set "$KA_I_AI" "$label"; title=$REPLY
    printf -v now '%(%H:%M:%S)T' -1
    if ka_tui_bar_supported; then
        ka_tui_status_colors "$KA_F_STATUS"
        ka_tui_bar_begin
        ka_tui_bar_add 4 7 "$title" 1
        ka_tui_bar_add "$KA_SEG_BG" "$KA_SEG_FG" "$KA_F_STATUS" 1
        ka_format_duration_set "$KA_F_MAIN_REMAIN"; duration=$REPLY
        ka_tui_bar_add 0 7 "main $duration"
        if [[ $KA_F_SEC_ENABLED == 1 ]]; then
            ka_format_duration_set "$KA_F_SEC_REMAIN"; duration=$REPLY
            ka_tui_bar_add 0 7 "sec $duration"
        fi
        ka_tui_bar_add 0 7 "$now"
        ka_tui_bar_end
        if ka_tui_bar_flush; then
            printf '%s\033[K\n' "$KA_G_V"
            return 0
        fi
    fi
    ka_tui_box_top "$KA_I_AI" "Keep Alive $label" "$now"
    printf '%s\033[K\n%s  Status          ' "$KA_G_V" "$KA_G_V"; ka_tui_status "$KA_F_STATUS"; printf '\n'
}

# Role: Render one metadata field without per-frame command substitutions.
ka_tui_detail_field() {
    local icon=$1 label=$2 value=$3 padding=$4 width=$5 rendered
    ka_icon_label_set "$icon" "$label"; rendered=$REPLY
    ka_tui_truncate_set "$value" "$width"; value=$REPLY
    printf '%s  %s%*s%s\033[K\n' "$KA_G_V" "$rendered" "$padding" '' "$value"
}

# Role: Render one existing keep-alive target detail view from atomic persisted state.
ka_tui_render_detail() {
    local uuid=$1 secondary='' cols frozen value_w bar_w label delivery notify last next_main next_secondary
    local prompt_w now_epoch
    if [[ ${KA_TUI_DETAIL_UUID:-} != "$uuid" || -z ${KA_TUI_DETAIL_CACHE_MARKER:-} ]]; then
        ka_tui_detail_cache_begin "$uuid" || return 1
    fi
    ka_tui_detail_cache_load "$uuid" || return 1
    ka_tui_detail_overlay_index "$uuid" || true
    secondary=$KA_TUI_DETAIL_SECONDARY

    ka_tui_frame_begin
    if ka_tui_too_small 52 16; then
        ka_tui_render_too_small 52 16
        ka_tui_frame_end
        return
    fi
    cols=${KA_TUI_COLS}
    ka_tui_field_width_set 22 12; value_w=$REPLY
    bar_w=16; ((cols < 76)) && bar_w=10
    frozen=''
    [[ $KA_F_STATUS == PAUSED || $KA_F_STATUS == UNAVAILABLE ]] && frozen=' · frozen'
    [[ ${KA_ASCII_MODE:-0} == 1 && -n $frozen ]] && frozen=' (frozen)'

    ka_tui_render_detail_header
    ka_tui_detail_field "$KA_I_TERM" 'Target' "$KA_F_TYPE" 10 "$value_w"
    ka_tui_detail_field "$KA_I_SERVICE" 'Backend' "$KA_F_BACKEND" 9 "$value_w"
    ka_tui_detail_field "$KA_I_DIR" 'Directory' "$KA_F_DIR" 7 "$value_w"
    ka_tui_detail_field "$KA_I_SESSION" 'Session' "$uuid" 9 "$value_w"
    ka_icon_label_set "$KA_I_ENTER" 'Delivery'; label=$REPLY
    [[ $KA_F_MODE == MESSAGE_ENTER ]] && delivery='MESSAGE + ENTER' || delivery='ENTER ONLY'
    printf '%s\033[K\n%s  %s        %s\033[K\n' "$KA_G_V" "$KA_G_V" "$label" "$delivery"
    ka_icon_label_set "$KA_I_NOTIFY" 'Notification'; label=$REPLY
    [[ $KA_F_NOTIFY == 1 ]] && notify=ON || notify=OFF
    printf '%s  %s    %s\033[K\n' "$KA_G_V" "$label" "$notify"

    if [[ $KA_F_STATUS == UNAVAILABLE ]]; then
        ka_tui_truncate_set "$KA_F_LAST" "$value_w"; label=$REPLY
        ka_tui_truncate_set "$KA_F_REASON" "$value_w"; last=$REPLY
        printf '%s\033[K\n%s  Last seen        %s\033[K\n%s  Reason           %s\033[K\n' "$KA_G_V" \
            "$KA_G_V" "$label" "$KA_G_V" "$last"
        ka_tui_field_width_set 3; prompt_w=$REPLY
        ka_tui_truncate_set 'Timers are frozen. This record remains until you delete it.' "$prompt_w"
        printf '%s\033[K\n%s  %s\033[K\n' "$KA_G_V" "$KA_G_V" "$REPLY"
    fi

    ka_tui_box_mid "$KA_I_TIMER" 'Timers'
    printf '%s\033[K\n' "$KA_G_V"
    ka_tui_render_timer_row MAIN "$KA_F_MAIN_REMAIN" "$KA_F_MAIN_INTERVAL" "$bar_w" "$frozen"
    if [[ $KA_F_SEC_ENABLED == 1 ]]; then
        local sec_note=$frozen
        # The secondary is a one-shot nudge; say so once it has fired.
        [[ ${KA_F_SEC_DONE:-0} == 1 ]] && sec_note=' · sent (one-shot)'
        ka_tui_render_timer_row SECONDARY "$KA_F_SEC_REMAIN" "$KA_F_SEC_INTERVAL" "$bar_w" "$sec_note"
        ka_tui_field_width_set 15 12; prompt_w=$REPLY
        ka_tui_truncate_set "$secondary" "$prompt_w"
        printf '%s  Prompt     %s\033[K\n' "$KA_G_V" "$REPLY"
    else
        printf '%s  SECONDARY  disabled\033[K\n' "$KA_G_V"
    fi

    next_main=${KA_F_NEXT_MAIN:-}
    if [[ $KA_F_STATUS == ACTIVE ]]; then
        if [[ -z $next_main ]]; then
            printf -v now_epoch '%(%s)T' -1
            printf -v next_main '%(%F %T)T' "$((now_epoch + KA_F_MAIN_REMAIN))"
        fi
    elif [[ $KA_F_STATUS == PAUSED ]]; then
        next_main='paused'
    else
        next_main='unavailable'
    fi
    if [[ $KA_F_SEC_ENABLED != 1 ]]; then
        next_secondary='disabled'
    elif [[ $KA_F_STATUS == ACTIVE && -n ${KA_F_NEXT_SECONDARY:-} ]]; then
        next_secondary=$KA_F_NEXT_SECONDARY
    elif [[ $KA_F_STATUS == ACTIVE ]]; then
        next_secondary='sent'
    elif [[ $KA_F_STATUS == PAUSED ]]; then
        next_secondary='paused'
    else
        next_secondary='unavailable'
    fi
    ka_tui_truncate_set "$next_main" "$value_w"; next_main=$REPLY
    ka_tui_truncate_set "$next_secondary" "$value_w"; next_secondary=$REPLY
    if [[ -z ${KA_F_LAST_DELIVERY_EVENT:-} ]]; then
        last='never'
    else
        last="${KA_F_LAST_DELIVERY_TIME#* } $KA_F_LAST_DELIVERY_EVENT $KA_F_LAST_DELIVERY_RESULT — $KA_F_LAST_DELIVERY_DETAIL"
    fi
    ka_tui_truncate_set "$last" "$value_w"; last=$REPLY
    printf '%s  Next main      %s\033[K\n' "$KA_G_V" "$next_main"
    printf '%s  Next secondary %s\033[K\n' "$KA_G_V" "$next_secondary"
    printf '%s  Last delivery  %s\033[K\n' "$KA_G_V" "$last"

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
    local label=$1 remain=$2 interval=$3 bar_w=$4 frozen=$5 remain_text interval_text
    printf '%s  %-11s' "$KA_G_V" "$label"
    ka_tui_progress "$remain" "$interval" "$bar_w"
    ka_format_duration_set "$remain"; remain_text=$REPLY
    if ((${KA_TUI_COLS:-80} >= 62)); then
        ka_format_duration_set "$interval"; interval_text=$REPLY
        printf '  %-10s   interval %s%s\033[K\n' "$remain_text" "$interval_text" "$frozen"
    else
        printf '  %s%s\033[K\n' "$remain_text" "$frozen"
    fi
}

# Role: List a target's stored message rotation and mark the entry that fires next.
# Kept separate so the glob-option change stays local instead of leaking to the caller.
ka_tui_render_message_rotation() {
    local index=$2 number=0 marker text_w text
    ka_tui_field_width_set 12 12; text_w=$REPLY
    for text in "${KA_TUI_DETAIL_MESSAGES[@]}"; do
        ((number += 1)); marker=' '
        ((number - 1 == index)) && marker=$KA_G_CUR
        ka_tui_truncate_set "$text" "$text_w"; text=$REPLY
        printf '%s   %s %2d. %s\033[K\n' "$KA_G_V" "$marker" "$number" "$text"
    done
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
    ka_tui_detail_cache_begin "$uuid" || return 0
    ka_state_target_dir "$uuid"
    local state_file="$REPLY/state.tsv"
    while [[ -r $state_file ]]; do
        ka_tui_index_changed && ka_tui_load_index
        ka_tui_render_detail "$uuid" || { ka_tui_detail_cache_end; return 0; }
        ka_tui_read_key 1 || continue
        key=$KA_KEY
        # KA_F_* were populated by the render above; no second parse of state.tsv.
        status=${KA_F_STATUS:-UNAVAILABLE}; type=${KA_F_TYPE-}; name=${KA_F_NAME-}
        case $key in
            ESC|q) ka_tui_detail_cache_end; return 0 ;;
            l|L) ka_tui_logs "$uuid" || true ;;
            d|D)
                if ka_tui_confirm_delete "$type / $name"; then
                    ka_tui_action DELETE "$uuid" || true
                    ka_tui_detail_cache_end
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
                    ka_tui_detail_cache_invalidate
                fi
                ;;
        esac
    done
    ka_tui_detail_cache_end
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

# Role: Stamp the client-presence file the daemon reads to choose its attached cadence.
# This file is data, not screen output: it must hold only the epoch seconds. An erase
# sequence once appended here made the daemon reject every stamp, so a watching TUI was
# never noticed and discovery stayed on the unattended cadence.
ka_tui_mark_presence() {
    printf '%(%s)T\n' -1 >"$KA_CLIENT_PRESENCE_FILE" 2>/dev/null || true
}

# Role: Hold a descriptor on the code this TUI was loaded from, and note the daemon it found.
# Both are what ka_tui_update_ready compares against once a second.
ka_tui_watch_install() {
    KA_TUI_SELF_FD=''
    KA_TUI_DAEMON_PID=''
    [[ -n ${KA_INVOKED_AS:-} && -n ${KA_ENTRYPOINT:-} && -r $KA_ENTRYPOINT ]] || return 0
    { exec {KA_TUI_SELF_FD}<"$KA_ENTRYPOINT"; } 2>/dev/null || { KA_TUI_SELF_FD=''; return 0; }
    ka_tui_read_service_state
    KA_TUI_DAEMON_PID=$KA_TUI_SERVICE_PID
}

# Role: Read the daemon's published pid and state into KA_TUI_SERVICE_PID/STATE with builtins.
ka_tui_read_service_state() {
    local key value
    KA_TUI_SERVICE_PID=''
    KA_TUI_SERVICE_STATE=''
    [[ -r $KA_SERVICE_STATE_FILE ]] || return 0
    while IFS=$'\t' read -r key value _; do
        case $key in
            pid) KA_TUI_SERVICE_PID=$value ;;
            state) KA_TUI_SERVICE_STATE=$value ;;
        esac
    done <"$KA_SERVICE_STATE_FILE" || true
}

# Role: Report whether an update installed new code and the daemon has restarted onto it.
#
# An update swaps the installed tree, so the command this TUI was started as now resolves
# to a different file than the one it holds open; `-ef` compares the two with stat calls
# and no fork. Waiting for a new, online daemon as well means the re-executed client is
# never left talking to a daemon that is just restarting. A TUI started from a checkout
# that the update did not touch keeps running as it is.
ka_tui_update_ready() {
    [[ -n ${KA_TUI_SELF_FD:-} ]] || return 1
    # Mid-swap the command can briefly not exist; that is not yet an update to load.
    [[ -e $KA_INVOKED_AS && ! $KA_INVOKED_AS -ef /dev/fd/$KA_TUI_SELF_FD ]] || return 1
    ka_tui_read_service_state
    [[ $KA_TUI_SERVICE_STATE == online && -n $KA_TUI_SERVICE_PID \
        && $KA_TUI_SERVICE_PID != "${KA_TUI_DAEMON_PID-}" ]]
}

# Role: Replace this TUI with the updated installation, keeping the highlighted row.
# The new version is test-loaded first (`--version` sources every module), because once
# exec succeeds there is no old client left to fall back to. If that or the exec fails, the
# old client carries on and stops watching, rather than retrying every second. The terminal
# is restored before the exec so the new process saves sane settings to restore later.
ka_tui_reexec() {
    local uuid=${1-} fd=$KA_TUI_SELF_FD
    if ! "$KA_INVOKED_AS" --version >/dev/null 2>&1; then
        { exec {fd}<&-; } 2>/dev/null || true
        KA_TUI_SELF_FD=''
        KA_TUI_TOAST='an update was installed, but it does not start; restart keepalive later'
        printf -v KA_TUI_TOAST_UNTIL '%(%s)T' -1
        KA_TUI_TOAST_UNTIL=$((KA_TUI_TOAST_UNTIL + 2))
        return 0
    fi
    ka_tui_leave
    { exec {fd}<&-; } 2>/dev/null || true
    KA_TUI_SELF_FD=''
    export KEEPALIVE_TUI_SELECT=$uuid
    shopt -s execfail
    # With execfail, a failed replacement returns here so the old TUI can restore its
    # terminal; a successful replacement must replace this process rather than fork.
    # shellcheck disable=SC2093
    exec "$KA_INVOKED_AS" ${KA_CLI_ARGS[@]+"${KA_CLI_ARGS[@]}"}
    shopt -u execfail
    unset KEEPALIVE_TUI_SELECT
    ka_tui_enter || return 1
    KA_TUI_TOAST='an update was installed, but it could not be started; restart keepalive later'
    printf -v KA_TUI_TOAST_UNTIL '%(%s)T' -1
    KA_TUI_TOAST_UNTIL=$((KA_TUI_TOAST_UNTIL + 2))
}

# Role: Run the attachable manager TUI; exiting this function never stops the daemon or timers.
ka_tui_main() {
    local response selected=0 offset=0 key n max_rows desired_uuid idx i
    # Stamped before the first request so the daemon, woken by that request, already
    # sees a watching client and switches to the attached cadence straight away.
    ka_tui_mark_presence
    response=$(ka_ipc_call PING '' 2>/dev/null || true)
    [[ $response == OK$'\t'* ]] || { ka_error "service unavailable: ${response#*$'\t'}"; return 1; }
    ka_ipc_call REFRESH '' >/dev/null 2>&1 || true
    ka_wizard_cleanup_stale
    ka_tui_enter || return
    ka_tui_watch_install

    local dirty=1 tick last_tick=''
    # Load once up front so the KA_R_* arrays exist even when the index is empty.
    ka_tui_load_index
    # A TUI re-executed after an update comes back on the row it was showing.
    if [[ -n ${KEEPALIVE_TUI_SELECT:-} ]]; then
        idx=$(ka_tui_find_uuid_index "$KEEPALIVE_TUI_SELECT") && selected=$idx
        unset KEEPALIVE_TUI_SELECT
    fi
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
            ka_tui_mark_presence
            # Once a second, and only on the manager screen: never mid-wizard input.
            if ka_tui_update_ready; then
                ka_tui_reexec "${KA_R_UUID[$selected]-}" || return 1
                dirty=1
            fi
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
