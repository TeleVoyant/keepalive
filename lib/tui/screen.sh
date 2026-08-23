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
    ka_tui_palette_init
    ka_tui_glyphs_init
}

# Role: Cache indexed foreground/background codes once so segment bars cost no forks per frame.
# Powerline segments need setab as well as setaf, which the plain color set never captured.
ka_tui_palette_init() {
    declare -ga KA_AF=() KA_AB=()
    local i
    if [[ ${KA_COLOR_ENABLED:-1} == 1 && -t 1 ]]; then
        for i in 0 1 2 3 4 5 6 7; do
            KA_AF[$i]=$(tput setaf "$i" 2>/dev/null || true)
            KA_AB[$i]=$(tput setab "$i" 2>/dev/null || true)
        done
    else
        for i in 0 1 2 3 4 5 6 7; do KA_AF[$i]='' KA_AB[$i]=''; done
    fi
}

# Role: Select box-drawing and marker glyphs so --ascii yields a fully 7-bit interface.
# Icons cover semantic glyphs only; these cover the frame itself, which --ascii used to miss.
ka_tui_glyphs_init() {
    if [[ ${KA_ASCII_MODE:-0} == 1 ]]; then
        KA_G_TL='+' KA_G_TR='+' KA_G_BL='+' KA_G_BR='+'
        KA_G_ML='+' KA_G_MR='+' KA_G_H='-' KA_G_V='|'
        KA_G_SEL='>' KA_G_CUR='->' KA_G_NONE='-' KA_G_ELL='...'
        KA_G_DOT_ON='*' KA_G_DOT_OFF='.'
    else
        KA_G_TL='╭' KA_G_TR='╮' KA_G_BL='╰' KA_G_BR='╯'
        KA_G_ML='├' KA_G_MR='┤' KA_G_H='─' KA_G_V='│'
        KA_G_SEL='❯' KA_G_CUR='→' KA_G_NONE='—' KA_G_ELL='…'
        KA_G_DOT_ON='●' KA_G_DOT_OFF='○'
    fi
    # Powerline wedges are Nerd Font private-use glyphs, so they follow icon mode, not
    # ASCII mode: --no-icons keeps colored segments but drops the wedge, which still
    # reads correctly because neighbouring segments differ in background color.
    # Written as \u escapes rather than literals so the encoding cannot be lost in transit.
    if [[ ${KA_ICONS_ENABLED:-1} == 1 && ${KA_ASCII_MODE:-0} != 1 ]]; then
        KA_G_PL_HEAD=$'\ue0b6'   # rounded left cap
        KA_G_PL_SEP=$'\ue0b0'    # solid right-pointing wedge
        KA_G_PL_TAIL=$'\ue0b4'   # rounded right cap
    else
        KA_G_PL_HEAD='' KA_G_PL_SEP='' KA_G_PL_TAIL=''
    fi
}

# Role: Report whether a colored powerline status bar can be drawn on this client.
# Without color the segments carry no meaning, so callers fall back to the boxed header.
ka_tui_bar_supported() {
    [[ ${KA_COLOR_ENABLED:-1} == 1 && -n ${KA_AB[4]:-} ]]
}

# Role: Begin accumulating a powerline-style segment bar.
ka_tui_bar_begin() {
    KA_BAR_OUT=''
    KA_BAR_PREV=''
    KA_BAR_WIDTH=0
}

# Role: Append one colored segment, drawing the wedge that joins it to the previous one.
ka_tui_bar_add() {
    local bg=$1 fg=$2 text=$3 bold=${4:-0} style=''
    ((bold == 1)) && style=$KA_BOLD
    if [[ -z $KA_BAR_PREV ]]; then
        # The head cap is the segment's own color painted on the default background.
        KA_BAR_OUT+="${KA_AF[$bg]}${KA_G_PL_HEAD}${KA_RESET}"
        KA_BAR_OUT+="${KA_AB[$bg]}${KA_AF[$fg]}${style} ${text} "
        KA_BAR_WIDTH=$((KA_BAR_WIDTH + ${#text} + 2 + ${#KA_G_PL_HEAD}))
    else
        # The wedge is painted in the previous segment's color over the new background.
        KA_BAR_OUT+="${KA_RESET}${KA_AB[$bg]}${KA_AF[$KA_BAR_PREV]}${KA_G_PL_SEP}"
        KA_BAR_OUT+="${KA_AB[$bg]}${KA_AF[$fg]}${style} ${text} "
        KA_BAR_WIDTH=$((KA_BAR_WIDTH + ${#text} + 2 + ${#KA_G_PL_SEP}))
    fi
    KA_BAR_PREV=$bg
}

# Role: Close a segment bar with a trailing wedge back onto the default background.
ka_tui_bar_end() {
    [[ -n $KA_BAR_PREV ]] || return 0
    KA_BAR_OUT+="${KA_RESET}${KA_AF[$KA_BAR_PREV]}${KA_G_PL_TAIL}${KA_RESET}"
    KA_BAR_WIDTH=$((KA_BAR_WIDTH + ${#KA_G_PL_TAIL}))
}

# Role: Print the accumulated segment bar when it fits the terminal, else report failure
# so the caller can render its plain fallback instead of emitting a wrapped bar.
ka_tui_bar_flush() {
    ((KA_BAR_WIDTH <= ${KA_TUI_COLS:-80})) || return 1
    printf '%s\033[K\n' "$KA_BAR_OUT"
}

# Role: Enter the alternate screen, hide cursor, and install safe restoration traps.
ka_tui_enter() {
    [[ -t 0 && -t 1 ]] || { ka_error 'interactive TUI requires a terminal'; return 1; }
    tput smcup 2>/dev/null || printf '\033[?1049h'
    tput civis 2>/dev/null || printf '\033[?25l'
    stty -echo 2>/dev/null || true
    KA_TUI_ACTIVE_VIEW=''
    KA_TUI_RESIZED=1
    ka_tui_sync_size
    trap ka_tui_leave EXIT
    trap 'KA_TUI_RESIZED=1' WINCH
    trap 'exit 130' INT
    trap 'exit 143' TERM
}

# Role: Restore cursor, echo, and the original terminal screen on all client exits.
# Also removes the client's scratch directory, which previously survived Ctrl-C and
# accumulated in the runtime directory for the rest of the login session.
ka_tui_leave() {
    stty echo 2>/dev/null || true
    tput cnorm 2>/dev/null || printf '\033[?25h'
    tput rmcup 2>/dev/null || printf '\033[?1049l'
    [[ -n ${KA_TUI_SCRATCH:-} ]] && rm -rf -- "$KA_TUI_SCRATCH" 2>/dev/null
    KA_TUI_SCRATCH=''
    return 0
}

# Role: Refresh cached terminal dimensions in one call instead of forking tput per query.
# Frames read these hundreds of times, so caching them is what keeps a redraw cheap.
ka_tui_sync_size() {
    local size='' lines='' cols=''
    if size=$(stty size 2>/dev/null); then
        lines=${size%% *}
        cols=${size##* }
    fi
    [[ $cols =~ ^[0-9]+$ ]] && ((cols > 0)) || cols=${COLUMNS:-80}
    [[ $lines =~ ^[0-9]+$ ]] && ((lines > 0)) || lines=${LINES:-24}
    [[ $cols =~ ^[0-9]+$ ]] && ((cols > 0)) || cols=80
    [[ $lines =~ ^[0-9]+$ ]] && ((lines > 0)) || lines=24
    KA_TUI_COLS=$cols
    KA_TUI_LINES=$lines
}

# Role: Return current terminal columns from the per-frame cache.
ka_tui_cols() {
    [[ -n ${KA_TUI_COLS:-} ]] || ka_tui_sync_size
    printf '%d' "$KA_TUI_COLS"
}

# Role: Return current terminal rows from the per-frame cache.
ka_tui_lines() {
    [[ -n ${KA_TUI_LINES:-} ]] || ka_tui_sync_size
    printf '%d' "$KA_TUI_LINES"
}

# Role: Start a frame and clear the visible screen when its view identity changes or resizes.
ka_tui_frame_begin() {
    local view=${1:-${FUNCNAME[1]:-unknown}} resized=${KA_TUI_RESIZED:-0}
    # Consume the current resize before emitting output so a WINCH arriving during
    # this frame remains set for the next frame instead of being overwritten.
    KA_TUI_RESIZED=0
    if [[ $view != "${KA_TUI_ACTIVE_VIEW:-}" || $resized == 1 ]]; then
        # Dimensions can only have changed across these same transitions, so this is
        # also the one place a size refresh is needed.
        ka_tui_sync_size
        # Clearing only on transitions avoids stale tails from a differently shaped
        # view without flashing the manager during its four redraws per second.
        printf '\033[H\033[2J'
    else
        printf '\033[H'
    fi
    KA_TUI_ACTIVE_VIEW=$view
}

# Role: Clear any remaining cells below the freshly rendered frame to prevent artifacts.
ka_tui_frame_end() {
    printf '\033[J'
}

# Role: Draw one full-width box rule with an optional inline label and right-aligned trailer.
# Widths are computed from the live terminal so frames never wrap or fall short of the edge.
ka_tui_box_rule() {
    local left=$1 right=$2 icon=${3-} label=${4-} trailer=${5-}
    local cols=${KA_TUI_COLS:-80} head='' tail='' used=2 fill i bar=''
    if [[ -n $label ]]; then
        if [[ -n $icon ]]; then
            head="$KA_G_H $icon $label "
            used=$((used + 4 + ${#label} + 1))
        else
            head="$KA_G_H $label "
            used=$((used + 3 + ${#label}))
        fi
    fi
    if [[ -n $trailer ]]; then
        tail=" $trailer $KA_G_H"
        used=$((used + 3 + ${#trailer}))
    fi
    fill=$((cols - used))
    ((fill < 1)) && fill=1
    for ((i = 0; i < fill; i++)); do bar+=$KA_G_H; done
    printf '%s%s%s%s%s\033[K\n' "$left" "$head" "$bar" "$tail" "$right"
}

# Role: Draw the top rule of a framed view.
ka_tui_box_top() {
    ka_tui_box_rule "$KA_G_TL" "$KA_G_TR" "${1-}" "${2-}" "${3-}"
}

# Role: Draw an interior section rule that divides a framed view.
ka_tui_box_mid() {
    ka_tui_box_rule "$KA_G_ML" "$KA_G_MR" "${1-}" "${2-}" "${3-}"
}

# Role: Draw the closing rule of a framed view.
ka_tui_box_bottom() {
    ka_tui_box_rule "$KA_G_BL" "$KA_G_BR" '' '' ''
}

# Role: Draw a plain horizontal rule that fits the terminal after an optional indent.
# Box rules always span the full width, so an indented one has to be sized separately.
ka_tui_hrule() {
    local indent=${1:-0} width i bar='' pad=''
    width=$((${KA_TUI_COLS:-80} - indent))
    ((width < 1)) && width=1
    for ((i = 0; i < indent; i++)); do pad+=' '; done
    for ((i = 0; i < width; i++)); do bar+=$KA_G_H; done
    printf '%s%s\033[K\n' "$pad" "$bar"
}

# Role: Report whether the terminal is large enough for a framed view to render legibly.
ka_tui_too_small() {
    local min_cols=${1:-52} min_lines=${2:-14}
    ((${KA_TUI_COLS:-80} < min_cols || ${KA_TUI_LINES:-24} < min_lines))
}

# Role: Render the shared "terminal too small" placeholder used by every framed view.
ka_tui_render_too_small() {
    local min_cols=${1:-52} min_lines=${2:-14}
    printf 'Keep Alive\033[K\n\033[K\nTerminal too small.\033[K\nResize to at least %dx%d (now %dx%d).\033[K\n' \
        "$min_cols" "$min_lines" "${KA_TUI_COLS:-0}" "${KA_TUI_LINES:-0}"
}

# Role: Derive a safe content width by reserving frame/label cells, never returning a
# zero or negative budget that would make truncation print the untruncated string.
ka_tui_field_width() {
    local reserved=${1:-0} minimum=${2:-8} width
    width=$((${KA_TUI_COLS:-80} - reserved))
    ((width < minimum)) && width=$minimum
    printf '%d' "$width"
}

# Role: Read one logical key, decoding arrow/Page/Home/End sequences byte by byte.
#
# Only a *bare* Escape means back/cancel. Every other escape sequence that this
# decoder does not recognize yields UNKNOWN, which no view acts on. The previous
# decoder read a fixed two bytes and mapped anything unrecognized to ESC, so
# Right/Left arrow, F-keys, keypad, and xterm's ESC [ n ~ keys all quit the view
# and, from the manager, exited the whole client.
ka_tui_read_key() {
    local timeout=${1:-1} key lead byte seq='' guard=0
    KA_KEY=''
    if [[ -n ${KA_TUI_PENDING_KEY:-} ]]; then
        # A byte read past a bare Escape on the previous call; deliver it now.
        key=$KA_TUI_PENDING_KEY
        KA_TUI_PENDING_KEY=''
    elif ! IFS= read -rsn1 -t "$timeout" key; then
        return 1
    fi
    if [[ $key != $'\e' ]]; then
        if [[ $key == $'\n' || $key == $'\r' || -z $key ]]; then KA_KEY=ENTER; else KA_KEY=$key; fi
        return 0
    fi

    # Nothing follows within the inter-byte window: a real Escape keypress.
    if ! IFS= read -rsn1 -t 0.05 lead; then
        KA_KEY=ESC
        return 0
    fi
    # CSI ("[") and SS3 ("O") introduce the sequences terminals actually send. Anything
    # else means Escape was its own keypress and this byte is the next keystroke, which
    # happens whenever a user types Escape and another key within the inter-byte window.
    # Queue it instead of discarding it, or that keystroke is silently lost.
    if [[ $lead != '[' && $lead != 'O' ]]; then
        KA_TUI_PENDING_KEY=$lead
        KA_KEY=ESC
        return 0
    fi
    seq=$lead
    # Consume through the terminating byte so its tail never leaks in as keystrokes.
    while ((guard < 12)); do
        IFS= read -rsn1 -t 0.05 byte || break
        seq+=$byte
        [[ $byte == [A-Za-z~] ]] && break
        ((guard += 1))
    done

    case $seq in
        '[A'|'OA') KA_KEY=UP ;;
        '[B'|'OB') KA_KEY=DOWN ;;
        '[C'|'OC') KA_KEY=RIGHT ;;
        '[D'|'OD') KA_KEY=LEFT ;;
        '[H'|'OH'|'[1~'|'[7~') KA_KEY=HOME ;;
        '[F'|'OF'|'[4~'|'[8~') KA_KEY=END ;;
        '[5~') KA_KEY=PGUP ;;
        '[6~') KA_KEY=PGDN ;;
        *) KA_KEY=UNKNOWN ;;
    esac
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

# Role: Pick segment background/foreground colors matching a target state.
# Sets KA_SEG_BG/KA_SEG_FG so the segment bars agree with ka_tui_status's plain colors.
ka_tui_status_colors() {
    case $1 in
        AVAILABLE) KA_SEG_BG=2; KA_SEG_FG=0 ;;
        ACTIVE) KA_SEG_BG=1; KA_SEG_FG=7 ;;
        PAUSED) KA_SEG_BG=3; KA_SEG_FG=0 ;;
        UNAVAILABLE) KA_SEG_BG=5; KA_SEG_FG=7 ;;
        *) KA_SEG_BG=3; KA_SEG_FG=0 ;;
    esac
}

# Role: Report how many terminal cells ka_tui_status occupies so callers can pad columns.
# The icon adds a glyph plus a space that the bare status word does not account for.
ka_tui_status_width() {
    local status=$1 width=${#1}
    [[ -n ${KA_I_ACTIVE:-} ]] && width=$((width + 2))
    printf '%d' "$width"
}

# Role: Choose timer urgency styling from the percentage of configured time remaining.
# Sets REPLY rather than printing; every progress bar called this, so a command
# substitution here cost one fork per rendered row.
ka_tui_timer_color() {
    local remaining=$1 interval=$2 pct=100
    if ((interval > 0)); then pct=$((remaining * 100 / interval)); fi
    if ((pct <= 10)); then
        REPLY="${KA_RED}${KA_BOLD}"
    elif ((pct <= 25)); then
        REPLY="${KA_YELLOW}${KA_BOLD}"
    elif ((pct <= 50)); then
        REPLY=$KA_YELLOW
    else
        REPLY=$KA_CYAN
    fi
}

# Role: Render a fixed-width depletion progress bar with urgency color and critical marker.
ka_tui_progress() {
    local remaining=$1 interval=$2 width=${3:-10} filled=0 empty pct=100 marker=''
    ((remaining < 0)) && remaining=0
    ((width < 1)) && width=1
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
    # shellcheck disable=SC2324  # bar is a string; += appends a glyph, which is the intent.
    local bar='' i
    for ((i=0; i<filled; i++)); do bar+=$full_char; done
    for ((i=0; i<empty; i++)); do bar+=$empty_char; done
    ka_tui_timer_color "$remaining" "$interval"
    printf '%s%s%s%s' "$REPLY" "$bar" "$KA_RESET" "$marker"
}

# Role: Remove every control byte from untrusted text before it reaches the screen.
# Message, directory, and process labels are user/filesystem data; an embedded escape
# sequence would otherwise repaint or reposition the live frame.
ka_tui_sanitize() {
    local value=${1-}
    value=${value//$'\t'/ }
    value=${value//$'\n'/ }
    value=${value//$'\r'/ }
    value=${value//[[:cntrl:]]/}
    printf '%s' "$value"
}

# Role: Truncate a display string to a maximum cell budget using a simple ellipsis policy.
# Control bytes are stripped inline (not via a subshell, because rows call this per field),
# and non-positive budgets yield nothing rather than falling through to printf's
# "precision omitted" behavior and printing the whole untruncated string.
#
# Width is counted in characters, not terminal cells; wide CJK/emoji still under-count.
# See docs/MAINTENANCE.md for that documented limitation.
ka_tui_truncate() {
    local text=${1-} width=$2 ellipsis=${KA_G_ELL:-…}
    text=${text//$'\t'/ }
    text=${text//$'\n'/ }
    text=${text//$'\r'/ }
    text=${text//[[:cntrl:]]/}
    if ((width <= 0)); then
        return 0
    elif ((${#text} <= width)); then
        printf '%s' "$text"
    elif ((width <= ${#ellipsis})); then
        printf '%.*s' "$width" "$text"
    else
        printf '%.*s%s' "$((width - ${#ellipsis}))" "$text" "$ellipsis"
    fi
}

# Role: Split one tab-separated record into KA_TSV without collapsing empty columns.
# Bash treats tab as IFS whitespace, so `read` silently merges adjacent tabs and shifts
# every later field; index rows legitimately contain empty columns.
ka_tui_split_tsv() {
    local line=${1-} field
    KA_TSV=()
    while [[ $line == *$'\t'* ]]; do
        field=${line%%$'\t'*}
        KA_TSV+=("$field")
        line=${line#*$'\t'}
    done
    KA_TSV+=("$line")
}

# Role: Show the cursor and read one edited line, returning it in KA_PROMPT_VALUE.
#
# The prompt, the cursor-visibility escapes, and the echo change must reach the
# terminal, not the caller. Callers used to capture this function's stdout with
# $(...), which folded the prompt text and every escape sequence into the returned
# value: typing "hello world" yielded
#   $'\E[?12l\E[?25h\nNew message\E(B\E[m: \E[?25lhello world'
# The embedded newline then failed daemon validation as a multi-line message, so
# every custom message, custom interval, and secondary prompt was rejected and only
# the untouched profile defaults could be saved.
#
# Returning through a global keeps the prompt on screen, keeps stty/tput acting on
# the real shell rather than a subshell, and hands back exactly what was typed.
ka_tui_prompt_line() {
    local prompt=$1 default=${2-} value
    KA_PROMPT_VALUE=''
    stty echo 2>/dev/null || true
    tput cnorm 2>/dev/null || printf '\033[?25h'
    printf '\033[K\n%s%s%s' "$KA_BOLD" "$prompt" "$KA_RESET"
    [[ -n $default ]] && printf ' [%s]' "$default"
    printf ': '
    IFS= read -r value || value=''
    tput civis 2>/dev/null || printf '\033[?25l'
    stty -echo 2>/dev/null || true
    value=${value:-$default}
    # Typed input is stored and later replayed into a terminal; keep it control-free.
    value=${value//$'\t'/ }
    value=${value//[[:cntrl:]]/}
    KA_PROMPT_VALUE=$value
}

# Role: Render a short transient action result at the bottom of the next screen frame.
ka_tui_toast() {
    KA_TUI_TOAST=$(ka_tui_sanitize "$1")
    KA_TUI_TOAST_UNTIL=$(( $(ka_now_epoch) + 2 ))
}

# Role: Print and expire the current transient action-result message.
ka_tui_render_toast() {
    local now
    now=$(ka_now_epoch)
    # A backward wall-clock correction must expire the toast rather than pin it forever.
    if [[ -n ${KA_TUI_TOAST:-} ]] && ((${KA_TUI_TOAST_UNTIL:-0} >= now && KA_TUI_TOAST_UNTIL - now <= 2)); then
        printf '\033[K\n  %s%s%s\033[K\n' "$KA_CYAN" "$(ka_tui_truncate "$KA_TUI_TOAST" "$(ka_tui_field_width 4)")" "$KA_RESET"
    else
        KA_TUI_TOAST=''
    fi
}
