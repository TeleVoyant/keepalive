#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
source "$TEST_ROOT/lib/icons.sh"
source "$TEST_ROOT/lib/tui/screen.sh"
KA_ICONS_ENABLED=0; KA_COLOR_ENABLED=0; KA_ASCII_MODE=1
ka_icons_init; ka_tui_style_init

# Role: Exercise implicit frame identity exactly as the manager renderer does.
test_render_manager_frame() { ka_tui_frame_begin; }

# Role: Exercise a distinct implicit frame identity exactly as a nested view does.
test_render_detail_frame() { ka_tui_frame_begin; }

# Role: Flush a segment bar while keeping the bar itself out of the test transcript.
flush_bar_quietly() { ka_tui_bar_flush >/dev/null; }

# Role: Report the cell count of a rendered frame rule, which never carries styling.
visible_width() {
    printf '%d' "${#1}"
}

assert_eq '#####-----' "$(ka_tui_progress 500 1000 10)" 'ASCII timer bar shows remaining-time depletion'
assert_eq '##-------- !' "$(ka_tui_progress 20 100 10)" 'critical timer bar adds urgency marker'
assert_eq 'AVAILABLE' "$(ka_tui_status AVAILABLE)" 'no-icons status remains semantically complete'

frame_output="$TEST_TMP/frame-output"
KA_TUI_ACTIVE_VIEW=''; KA_TUI_RESIZED=0; KA_TUI_COLS=80; KA_TUI_LINES=24
test_render_manager_frame >"$frame_output"
assert_eq $'\033[H\033[2J' "$(cat "$frame_output")" 'first TUI frame clears the visible screen'
test_render_manager_frame >"$frame_output"
assert_eq $'\033[H' "$(cat "$frame_output")" 'same-view redraw avoids a flickering full clear'
test_render_detail_frame >"$frame_output"
assert_eq $'\033[H\033[2J' "$(cat "$frame_output")" 'view transition clears previous-view artifacts'
KA_TUI_RESIZED=1
test_render_detail_frame >"$frame_output"
assert_eq $'\033[H\033[2J' "$(cat "$frame_output")" 'terminal resize forces a clean frame'
assert_eq 0 "$KA_TUI_RESIZED" 'clean frame consumes the resize invalidation flag'

# Truncation must never fall through to printf's "precision omitted" behavior, which
# printed the whole string whenever a derived width went non-positive on a narrow screen.
assert_eq '' "$(ka_tui_truncate '/long/path/that/must/not/appear' -4)" 'negative width truncates to nothing'
assert_eq '' "$(ka_tui_truncate 'abcdef' 0)" 'zero width truncates to nothing'
assert_eq 'ab' "$(ka_tui_truncate 'abcdef' 2)" 'width below the ellipsis budget hard-cuts'
assert_eq 'ab...' "$(ka_tui_truncate 'abcdef' 5)" 'ASCII mode truncates with an ASCII ellipsis'
assert_eq 'abcdef' "$(ka_tui_truncate 'abcdef' 6)" 'exact-fit text is not truncated'
assert_eq 'hello[31mRED' "$(ka_tui_truncate $'hello\033[31mRED\a' 40)" 'control bytes are stripped before rendering'

# Bash treats tab as IFS whitespace, so `read` collapsed adjacent empty index columns
# and shifted every later field. Empty columns are legitimate in AVAILABLE rows.
ka_tui_split_tsv "$(printf 'a\tb\t\tc\t\t')"
assert_eq 6 "${#KA_TSV[@]}" 'tab split preserves empty and trailing columns'
assert_eq '' "${KA_TSV[2]}" 'interior empty column keeps its position'
assert_eq 'c' "${KA_TSV[3]}" 'column after an empty one does not shift'

# Frames are drawn from live width; the old fixed-width literals wrapped or fell short.
for width in 52 80 100 137; do
    KA_TUI_COLS=$width
    assert_eq "$width" "$(visible_width "$(ka_tui_box_top '' 'Keep Alive Manager' '12:00:00')")" \
        "box top fills exactly $width columns"
    assert_eq "$width" "$(visible_width "$(ka_tui_box_bottom)")" "box bottom fills exactly $width columns"
    assert_eq "$width" "$(visible_width "$(ka_tui_hrule 2)")" "indented rule plus indent fills exactly $width columns"
done

KA_TUI_COLS=80
assert_eq 8 "$(ka_tui_field_width 100 8)" 'derived field width clamps to its minimum'
assert_eq 60 "$(ka_tui_field_width 20)" 'derived field width subtracts the reserved cells'

# --ascii must yield a fully 7-bit frame, not only ASCII progress bars.
KA_ASCII_MODE=1; ka_tui_glyphs_init
glyphs="$KA_G_TL$KA_G_TR$KA_G_BL$KA_G_BR$KA_G_ML$KA_G_MR$KA_G_H$KA_G_V$KA_G_SEL$KA_G_CUR$KA_G_NONE$KA_G_ELL"
assert_eq '' "${glyphs//[[:ascii:]]/}" 'ASCII mode uses only 7-bit frame glyphs'
assert_eq '' "$(ka_tui_progress 500 1000 4 | tr -d '[:ascii:]')" 'ASCII mode progress bar is 7-bit'
assert_eq '' "$KA_G_PL_SEP" 'ASCII mode drops the Nerd Font powerline wedge'
KA_ASCII_MODE=0; KA_ICONS_ENABLED=1; ka_tui_glyphs_init
assert_eq $'' "$KA_G_PL_SEP" 'icon mode selects the powerline wedge glyph'
KA_ICONS_ENABLED=0; ka_tui_glyphs_init
assert_eq '' "$KA_G_PL_SEP" 'no-icons mode keeps segments but drops the wedge'

# Status column padding must come from rendered cells; the icon adds two the word lacks.
KA_ICONS_ENABLED=0; ka_icons_init
assert_eq 6 "$(ka_tui_status_width ACTIVE)" 'no-icons status width is the bare word'
KA_ICONS_ENABLED=1; ka_icons_init
assert_eq 8 "$(ka_tui_status_width ACTIVE)" 'icon status width includes the glyph and its space'

# Segment bars degrade rather than emitting a wrapped or colorless bar.
KA_COLOR_ENABLED=0; ka_tui_palette_init
assert_false 'segment bar is unsupported without color' ka_tui_bar_supported
declare -ga KA_AF=() KA_AB=()
for i in 0 1 2 3 4 5 6 7; do KA_AF[$i]="<f$i>"; KA_AB[$i]="<b$i>"; done
KA_COLOR_ENABLED=1; KA_ICONS_ENABLED=0; ka_tui_glyphs_init
assert_true 'segment bar is supported once background colors exist' ka_tui_bar_supported
ka_tui_bar_begin
ka_tui_bar_add 4 7 'Keep Alive'
ka_tui_bar_add 2 0 'online'
ka_tui_bar_end
assert_eq 20 "$KA_BAR_WIDTH" 'segment bar tracks its own visible width'
KA_TUI_COLS=10
assert_false 'oversized segment bar refuses to print so the caller can fall back' flush_bar_quietly
KA_TUI_COLS=80
assert_true 'segment bar prints when it fits' flush_bar_quietly

# Key decoding. Only a bare Escape may mean back/cancel: the previous decoder read a
# fixed two bytes and mapped anything unrecognized to ESC, so Right/Left, F-keys and
# xterm's ESC [ n ~ keys quit the view and exited the client from the manager.
# Role: Decode every key in one byte stream and return the logical names, space separated.
decode_keys() {
    local bytes=$1 out='' file="$TEST_TMP/keys.bin" kfd
    printf '%b' "$bytes" >"$file"
    KA_TUI_PENDING_KEY=''
    exec {kfd}<"$file"
    while ka_tui_read_key 0.2 <&"$kfd"; do out+="$KA_KEY "; done
    exec {kfd}<&-
    printf '%s' "${out% }"
}

assert_eq 'UP'      "$(decode_keys '\033[A')"   'CSI A decodes as UP'
assert_eq 'DOWN'    "$(decode_keys '\033[B')"   'CSI B decodes as DOWN'
assert_eq 'RIGHT'   "$(decode_keys '\033[C')"   'CSI C decodes as RIGHT, not a quit'
assert_eq 'LEFT'    "$(decode_keys '\033[D')"   'CSI D decodes as LEFT, not a quit'
assert_eq 'PGUP'    "$(decode_keys '\033[5~')"  'CSI 5~ decodes as PGUP'
assert_eq 'PGDN'    "$(decode_keys '\033[6~')"  'CSI 6~ decodes as PGDN'
assert_eq 'HOME'    "$(decode_keys '\033[1~')"  'xterm CSI 1~ decodes as HOME'
assert_eq 'END'     "$(decode_keys '\033[4~')"  'xterm CSI 4~ decodes as END'
assert_eq 'HOME'    "$(decode_keys '\033OH')"   'SS3 H decodes as HOME'
assert_eq 'UNKNOWN' "$(decode_keys '\033OP')"   'F1 is ignored rather than quitting the view'
assert_eq 'UNKNOWN' "$(decode_keys '\033[15~')" 'F5 is ignored rather than quitting the view'
assert_eq 'UNKNOWN' "$(decode_keys '\033[200~')" 'bracketed-paste marker is ignored, not a quit'
assert_eq 'ESC'     "$(decode_keys '\033')"     'a bare Escape still means back/cancel'
assert_eq 'ENTER'   "$(decode_keys '\r')"       'carriage return decodes as ENTER'
assert_eq 'j'       "$(decode_keys 'j')"        'plain characters pass through'
# Escape followed quickly by another key must keep both; the follow-up byte was dropped.
assert_eq 'ESC q'   "$(decode_keys '\033q')"    'Escape then a fast keystroke preserves both keys'
assert_eq 'ESC ESC' "$(decode_keys '\033\033')" 'two fast Escapes are both delivered'
assert_eq 'UP DOWN' "$(decode_keys '\033[A\033[B')" 'consecutive sequences decode independently'

test_finish
