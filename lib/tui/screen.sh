#!/usr/bin/env bash
# Low-level terminal presentation primitives for the attachable TUI client.

# Role: Initialize terminal colors and styling while respecting NO_COLOR/--no-color.
ka_tui_style_init() {
    if [[ ${KA_COLOR_ENABLED:-1} == 1 && -t 1 ]]; then
        KA_BOLD=$(tput bold 2>/dev/null || true)
        KA_DIM=$(tput dim 2>/dev/null || true)
        KA_RED=$(tput setaf 1 2>/dev/null || true)
        KA_GREEN=$(tput setaf 2 2>/dev/null || true)
        KA_YELLOW=$(tput setaf 3 2>/dev/null || true)
        KA_CYAN=$(tput setaf 6 2>/dev/null || true)
        KA_WHITE=$(tput setaf 7 2>/dev/null || true)
        KA_RESET=$(tput sgr0 2>/dev/null || true)
    else
        KA_BOLD='' KA_DIM='' KA_RED='' KA_GREEN='' KA_YELLOW='' KA_CYAN='' KA_WHITE='' KA_RESET=''
    fi
}

# Role: Enter the alternate screen, hide cursor, and install safe restoration traps.
ka_tui_enter() {
    [[ -t 0 && -t 1 ]] || { ka_error 'interactive TUI requires a terminal'; return 1; }
    tput smcup 2>/dev/null || printf '\033[?1049h'
    tput civis 2>/dev/null || printf '\033[?25l'
    stty -echo 2>/dev/null || true
    trap ka_tui_leave EXIT
    trap 'KA_TUI_RESIZED=1' WINCH
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# Role: Restore cursor, echo, and the original terminal screen on all client exits.
ka_tui_leave() {
    stty echo 2>/dev/null || true
    tput cnorm 2>/dev/null || printf '\033[?25h'
    tput rmcup 2>/dev/null || printf '\033[?1049l'
}

# Role: Return current terminal columns with a conservative fallback.
ka_tui_cols() {
    local cols
    cols=$(tput cols 2>/dev/null || printf 80)
    printf '%d' "$cols"
}

# Role: Return current terminal rows with a conservative fallback.
ka_tui_lines() {
    local lines
    lines=$(tput lines 2>/dev/null || printf 24)
    printf '%d' "$lines"
}

# Role: Move rendering to the top-left and clear all stale content below the new frame.
ka_tui_frame_begin() {
    printf '\033[H'
}

# Role: Clear any remaining cells below the freshly rendered frame to prevent artifacts.
ka_tui_frame_end() {
    printf '\033[J'
}

# Role: Read one logical key, decoding common arrow/Page/Home/End escape sequences.
ka_tui_read_key() {
    local timeout=${1:-1} key rest=''
    KA_KEY=''
    if ! IFS= read -rsn1 -t "$timeout" key; then
        return 1
    fi
    if [[ $key == $'\e' ]]; then
        IFS= read -rsn2 -t 0.05 rest || true
        case "$rest" in
            '[A') KA_KEY=UP ;;
            '[B') KA_KEY=DOWN ;;
            '[5') IFS= read -rsn1 -t 0.02 _ || true; KA_KEY=PGUP ;;
            '[6') IFS= read -rsn1 -t 0.02 _ || true; KA_KEY=PGDN ;;
            '[H') KA_KEY=HOME ;;
            '[F') KA_KEY=END ;;
            '')   KA_KEY=ESC ;;
            *)    KA_KEY=ESC ;;
        esac
    elif [[ $key == $'\n' || $key == $'\r' || -z $key ]]; then
        KA_KEY=ENTER
    else
        KA_KEY=$key
    fi
    return 0
}

# Role: Render a status label using the canonical AVAILABLE/ACTIVE/PAUSED/UNAVAILABLE colors.
ka_tui_status() {
    local status=$1 icon='' color=''
    case $status in
        AVAILABLE) icon=$KA_I_AVAILABLE; color="${KA_GREEN}${KA_BOLD}" ;;
        ACTIVE) icon=$KA_I_ACTIVE; color="${KA_RED}${KA_BOLD}" ;;
        PAUSED) icon=$KA_I_PAUSED; color=$KA_YELLOW ;;
        UNAVAILABLE) icon=$KA_I_UNAVAILABLE; color="${KA_DIM}${KA_RED}" ;;
        *) icon=$KA_I_WARN; color=$KA_YELLOW ;;
    esac
    if [[ -n $icon ]]; then
        printf '%s%s %s%s' "$color" "$icon" "$status" "$KA_RESET"
    else
        printf '%s%s%s' "$color" "$status" "$KA_RESET"
    fi
}

# Role: Choose timer urgency styling from the percentage of configured time remaining.
ka_tui_timer_color() {
    local remaining=$1 interval=$2 pct=100
    if ((interval > 0)); then pct=$((remaining * 100 / interval)); fi
    if ((pct <= 10)); then
        printf '%s%s' "$KA_RED" "$KA_BOLD"
    elif ((pct <= 25)); then
        printf '%s%s' "$KA_YELLOW" "$KA_BOLD"
    elif ((pct <= 50)); then
        printf '%s' "$KA_YELLOW"
    else
        printf '%s' "$KA_CYAN"
    fi
}

# Role: Render a fixed-width depletion progress bar with urgency color and critical marker.
ka_tui_progress() {
    local remaining=$1 interval=$2 width=${3:-10} filled=0 empty pct=100 marker=''
    ((remaining < 0)) && remaining=0
    if ((interval > 0)); then
        pct=$((remaining * 100 / interval))
        filled=$((remaining * width / interval))
    else
        filled=0
    fi
    ((filled < 0)) && filled=0
    ((filled > width)) && filled=$width
    empty=$((width - filled))
    ((remaining <= 60 && interval > 0)) && marker=' !'
    ((remaining <= 10 && interval > 0)) && marker=' !!'

    local full_char='█' empty_char='░'
    if [[ ${KA_ASCII_MODE:-0} == 1 ]]; then full_char='#'; empty_char='-'; fi
    local bar='' i
    for ((i=0; i<filled; i++)); do bar+=$full_char; done
    for ((i=0; i<empty; i++)); do bar+=$empty_char; done
    printf '%s%s%s%s' "$(ka_tui_timer_color "$remaining" "$interval")" "$bar" "$KA_RESET" "$marker"
}

# Role: Truncate a display string to a maximum cell budget using a simple ellipsis policy.
ka_tui_truncate() {
    local text=$1 width=$2
    if ((${#text} <= width)); then
        printf '%s' "$text"
    elif ((width <= 1)); then
        printf '%.*s' "$width" "$text"
    else
        printf '%.*s…' "$((width - 1))" "$text"
    fi
}

# Role: Temporarily show the cursor and read one editable line inside a guided TUI form.
ka_tui_prompt_line() {
    local prompt=$1 default=${2-} value
    stty echo 2>/dev/null || true
    tput cnorm 2>/dev/null || printf '\033[?25h'
    printf '\n%s%s%s' "$KA_BOLD" "$prompt" "$KA_RESET"
    [[ -n $default ]] && printf ' [%s]' "$default"
    printf ': '
    IFS= read -r value || value=''
    tput civis 2>/dev/null || printf '\033[?25l'
    stty -echo 2>/dev/null || true
    printf '%s' "${value:-$default}"
}

# Role: Render a short transient action result at the bottom of the next screen frame.
ka_tui_toast() {
    KA_TUI_TOAST=$1
    KA_TUI_TOAST_UNTIL=$(( $(ka_now_epoch) + 2 ))
}

# Role: Print and expire the current transient action-result message.
ka_tui_render_toast() {
    local now
    now=$(ka_now_epoch)
    if [[ -n ${KA_TUI_TOAST:-} && ${KA_TUI_TOAST_UNTIL:-0} -ge $now ]]; then
        printf '\n  %s%s%s\n' "$KA_CYAN" "$KA_TUI_TOAST" "$KA_RESET"
    else
        KA_TUI_TOAST=''
    fi
}
