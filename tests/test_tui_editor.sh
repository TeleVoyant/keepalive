#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
source "$TEST_ROOT/lib/icons.sh"
source "$TEST_ROOT/lib/tui/screen.sh"
source "$TEST_ROOT/lib/tui/tui.sh"
source "$TEST_ROOT/lib/tui/wizard.sh"

KA_ICONS_ENABLED=0
KA_COLOR_ENABLED=0
KA_ASCII_MODE=1
KA_TUI_COLS=80
KA_TUI_LINES=24
ka_icons_init
ka_tui_style_init

# Role: Write one test scalar without adding a newline, matching the editor's scratch files.
write_editor_scalar() {
    local path=$1 value=$2
    printf '%s' "$value" >"$path"
}

# Role: Build a scratch settings directory with every editable field present.
make_editor_config() {
    local dir=$1
    mkdir -p "$dir/messages"
    write_editor_scalar "$dir/main_interval" 1500
    write_editor_scalar "$dir/secondary_enabled" 0
    write_editor_scalar "$dir/secondary_interval" 600
    write_editor_scalar "$dir/secondary_message" 'Continue if there is unfinished work.'
    write_editor_scalar "$dir/notifications" 0
    write_editor_scalar "$dir/delivery_mode" MESSAGE_ENTER
    write_editor_scalar "$dir/profile_update" 1
    write_editor_scalar "$dir/messages/001" alpha
    write_editor_scalar "$dir/messages/002" beta
}

# Role: Create the matching index publication and checkpoint for one live-refresh snapshot.
write_live_snapshot() {
    local status=$1 main_left=$2 main_interval=$3 sec_enabled=$4 sec_left=$5 sec_interval=$6 sec_done=$7
    local target_dir row
    ka_state_target_dir "$LIVE_UUID"
    target_dir=$REPLY
    mkdir -p "$target_dir/messages"
    {
        printf 'backend\tkonsole\n'
        printf 'type\tCodex\n'
        printf 'name\tEditor test\n'
        printf 'directory\t/tmp\n'
        printf 'status\t%s\n' "$status"
        printf 'mode\tMESSAGE_ENTER\n'
        printf 'notifications\t0\n'
        printf 'main_interval\t%s\n' "$main_interval"
        printf 'main_remaining\t%s\n' "$main_left"
        printf 'main_index\t0\n'
        printf 'secondary_enabled\t%s\n' "$sec_enabled"
        printf 'secondary_interval\t%s\n' "$sec_interval"
        printf 'secondary_remaining\t%s\n' "$sec_left"
        printf 'secondary_done\t%s\n' "$sec_done"
        printf 'secondary_message_file\tsecondary_message\n'
    } >"$target_dir/state.tsv"
    printf -v row '%s\tCodex\tEditor test\t/tmp\t%s\t%s\t%s\t%s\t%s\t%s\tMESSAGE_ENTER\t0\t\t\tkonsole\t\t\t\t\t\t' \
        "$LIVE_UUID" "$status" "$main_left" "$main_interval" "$sec_enabled" "$sec_left" "$sec_interval"
    printf '%s\n' "$row" >"$KA_INDEX_FILE"
}

# Role: Replace the injected monotonic reading with one whole-second timestamp.
set_editor_clock() {
    printf '%s.000000 0.000000\n' "$1" >"$KEEPALIVE_MONOTONIC_FILE"
}

# Role: Check that every rendered content line is erased and fits the requested width.
editor_frame_fits() {
    local path=$1 cols=$2 line visible
    while IFS= read -r line || [[ -n $line ]]; do
        [[ $line == $'\033[J' ]] && continue
        [[ $line == *$'\033[K' ]] || return 1
        visible=${line//$'\033[K'/}
        visible=${visible//$'\033[H'/}
        visible=${visible//$'\033[2J'/}
        (( ${#visible} <= cols )) || return 1
    done <"$path"
}

# Role: Report whether two captured message signatures differ.
editor_signatures_differ() {
    [[ $1 != "$2" ]]
}

# Role: Confirm every trace entry came from the caller process.
editor_trace_is_single_process() {
    local path=$1 expected="+$BASHPID"
    awk -v expected="$expected" \
        '$1 ~ /^\+[0-9]+$/ { seen=1; if ($1 != expected) bad=1 } END { exit (!seen || bad) }' "$path"
}

# Role: Confirm every helper probe in a log ran in this shell.
editor_pid_log_is_current() {
    local path=$1
    awk -v expected="$BASHPID" '$1 != expected { bad=1 } END { exit bad }' "$path"
}

read_path="$TEST_TMP/read-value"
ka_wizard_read_set "$TEST_TMP/not-created"
assert_eq '' "$REPLY" 'an absent scratch scalar reads as empty'
printf 'one line\n' >"$read_path"
ka_wizard_read_set "$read_path"
assert_eq 'one line' "$REPLY" 'the scalar reader drops one final LF'
printf 'carriage\r\n' >"$read_path"
ka_wizard_read_set "$read_path"
assert_eq $'carriage\r' "$REPLY" 'CR remains content when stripping a final LF'
printf 'symlink value' >"$TEST_TMP/symlink-target"
ln -s "$TEST_TMP/symlink-target" "$TEST_TMP/symlink-scalar"
ka_wizard_read_set "$TEST_TMP/symlink-scalar"
assert_eq '' "$REPLY" 'a symlinked scratch scalar reads as empty'

base_config="$TEST_TMP/editor-base"
make_editor_config "$base_config"
ka_wizard_describe_set "$base_config" messages
assert_eq '2 messages, first: alpha' "$REPLY" 'messages field describes count and first value'
assert_eq '5:001:alpha;4:002:beta;' "$KA_WIZARD_SIGNATURE" 'messages signature length-prefixes each ordered entry'
ka_wizard_describe_set "$base_config" main
assert_eq '25:00' "$REPLY" 'main field describes its formatted interval'
assert_eq 1500 "$KA_WIZARD_SIGNATURE" 'main signature retains the scalar interval'
ka_wizard_describe_set "$base_config" secondary
assert_eq off "$REPLY" 'disabled secondary field describes as off'
assert_eq 0 "$KA_WIZARD_SIGNATURE" 'disabled secondary field has the off signature'
write_editor_scalar "$base_config/secondary_enabled" 1
ka_wizard_describe_set "$base_config" secondary
assert_eq 'once after 10:00: Continue if there is unfinished work.' "$REPLY" \
    'enabled secondary field describes its interval and message'
assert_eq $'1\037600\037Continue if there is unfinished work.' "$KA_WIZARD_SIGNATURE" \
    'enabled secondary signature includes enabled state, interval, and message'
write_editor_scalar "$base_config/secondary_enabled" 0
ka_wizard_describe_set "$base_config" notifications
assert_eq OFF "$REPLY" 'notifications field describes disabled as OFF'
assert_eq 0 "$KA_WIZARD_SIGNATURE" 'notifications signature retains its scalar value'
ka_wizard_describe_set "$base_config" delivery
assert_eq 'MESSAGE + ENTER' "$REPLY" 'delivery field describes message plus Enter mode'
assert_eq MESSAGE_ENTER "$KA_WIZARD_SIGNATURE" 'delivery signature retains the mode scalar'
ka_wizard_describe_set "$base_config" profile
assert_eq yes "$REPLY" 'profile field defaults to yes when present'
assert_eq 1 "$KA_WIZARD_SIGNATURE" 'profile signature defaults to one when present'
rm "$base_config/profile_update"
ka_wizard_describe_set "$base_config" profile
assert_eq yes "$REPLY" 'profile field defaults to yes when absent'
assert_eq 1 "$KA_WIZARD_SIGNATURE" 'absent profile signature defaults to one'
write_editor_scalar "$base_config/profile_update" 1

rotation_many="$TEST_TMP/rotation-many"
rotation_one="$TEST_TMP/rotation-one"
mkdir -p "$rotation_many/messages" "$rotation_one/messages"
write_editor_scalar "$rotation_many/messages/001" a
write_editor_scalar "$rotation_many/messages/002" b
write_editor_scalar "$rotation_one/messages/001" $'a\037b'
ka_wizard_describe_set "$rotation_many" messages
many_signature=$KA_WIZARD_SIGNATURE
ka_wizard_describe_set "$rotation_one" messages
one_signature=$KA_WIZARD_SIGNATURE
assert_true 'length-prefixed rotation signatures distinguish a separator collision' \
    editor_signatures_differ "$many_signature" "$one_signature"

ka_wizard_describe_all "$base_config" WAS
ka_wizard_describe_all "$base_config" NOW
assert_false 'identical descriptions are not dirty' ka_wizard_dirty
for field_index in 0 1 2 3 4 5; do
    changed_config="$TEST_TMP/editor-changed-$field_index"
    cp -a -- "$base_config" "$changed_config"
    case $field_index in
        0) write_editor_scalar "$changed_config/messages/001" gamma ;;
        1) write_editor_scalar "$changed_config/main_interval" 900 ;;
        2)
            write_editor_scalar "$changed_config/secondary_enabled" 1
            write_editor_scalar "$changed_config/secondary_message" enabled
            ;;
        3) write_editor_scalar "$changed_config/notifications" 1 ;;
        4) write_editor_scalar "$changed_config/delivery_mode" ENTER_ONLY ;;
        5) write_editor_scalar "$changed_config/profile_update" 0 ;;
    esac
    ka_wizard_describe_all "$changed_config" NOW
    assert_true "editing ${KA_WIZARD_FIELDS[$field_index]} makes the editor dirty" ka_wizard_dirty
done
final_lf_config="$TEST_TMP/editor-final-lf"
cp -a -- "$base_config" "$final_lf_config"
printf 'alpha\n' >"$final_lf_config/messages/001"
ka_wizard_describe_all "$final_lf_config" NOW
assert_false 'adding one final LF to a saved message does not make the editor dirty' ka_wizard_dirty

KA_F_STATUS=ACTIVE
ka_wizard_countdown_effect_set 'Main countdown' 700 600
assert_eq 'Main countdown: 11:40 left, capped at 10:00 on save.' "$REPLY" \
    'countdown effect describes a cap when the new interval is shorter'
ka_wizard_countdown_effect_set 'Main countdown' 300 600
assert_eq 'Main countdown keeps running: 05:00 left.' "$REPLY" \
    'countdown effect says the timer keeps running when it fits'
KA_F_STATUS=PAUSED
ka_wizard_countdown_effect_set 'Main countdown' 300 600
assert_eq 'Main countdown stays paused with 05:00 left.' "$REPLY" \
    'paused countdown effect says the timer stays frozen'
KA_F_STATUS=ACTIVE
ka_wizard_countdown_effect_set 'Main countdown' invalid invalid
assert_eq 'Main countdown keeps running: 00:00 left.' "$REPLY" \
    'non-numeric countdown values fall back to zero'

enabled_config="$TEST_TMP/editor-enabled-base"
cp -a -- "$base_config" "$enabled_config"
write_editor_scalar "$enabled_config/secondary_enabled" 1

# Role: Prepare a fresh editor/original pair and cache their field descriptions.
reset_effect_pair() {
    local label=$1 source=$2 root
    root="$TEST_TMP/effect-$label"
    mkdir -p "$root"
    cp -a -- "$source" "$root/original"
    cp -a -- "$source" "$root/config"
    KA_WIZ_ORIGINAL="$root/original"
    KA_WIZ_DIR="$root/config"
    ka_wizard_describe_all "$KA_WIZ_ORIGINAL" WAS
    ka_wizard_describe_all "$KA_WIZ_DIR" NOW
}

reset_effect_pair create "$base_config"
ka_wizard_effects CREATE
assert_eq 'Press s to start this keep-alive with these settings.' "${KA_WIZ_EFFECTS[0]}" \
    'CREATE effect explains how to start the new keep-alive'
KA_F_STATUS=ACTIVE
ka_wizard_effects CONFIGURE
assert_eq 'No changes yet. The countdowns keep running while you edit.' "${KA_WIZ_EFFECTS[0]}" \
    'unchanged ACTIVE configuration says countdowns keep running'
KA_F_STATUS=PAUSED
ka_wizard_effects CONFIGURE
assert_eq 'No changes yet. This keep-alive is paused; its countdowns are frozen.' "${KA_WIZ_EFFECTS[0]}" \
    'unchanged PAUSED configuration says countdowns are frozen'

KA_F_STATUS=ACTIVE
KA_WIZ_MAIN_LEFT=1000
reset_effect_pair main-short "$base_config"
write_editor_scalar "$KA_WIZ_DIR/main_interval" 900
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
ka_wizard_effects CONFIGURE
assert_eq 'Main countdown: 16:40 left, capped at 15:00 on save.' "${KA_WIZ_EFFECTS[0]}" \
    'shorter main interval caps the current countdown'
reset_effect_pair main-long "$base_config"
write_editor_scalar "$KA_WIZ_DIR/main_interval" 1800
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
ka_wizard_effects CONFIGURE
assert_eq 'Main countdown keeps running: 16:40 left.' "${KA_WIZ_EFFECTS[0]}" \
    'longer main interval keeps the current countdown'
reset_effect_pair rotation "$base_config"
write_editor_scalar "$KA_WIZ_DIR/messages/001" changed
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
ka_wizard_effects CONFIGURE
assert_eq 'Messages changed: the rotation restarts at message 1, and an owed Enter is dropped.' \
    "${KA_WIZ_EFFECTS[0]}" 'rotation change explains restart at message one'

KA_WIZ_SEC_LEFT=700
reset_effect_pair secondary-off "$enabled_config"
write_editor_scalar "$KA_WIZ_DIR/secondary_enabled" 0
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
ka_wizard_effects CONFIGURE
assert_eq 'Secondary prompt turns off; an owed secondary Enter is dropped.' "${KA_WIZ_EFFECTS[0]}" \
    'disabling secondary prompt explains an owed secondary Enter is dropped'
reset_effect_pair secondary-new "$base_config"
write_editor_scalar "$KA_WIZ_DIR/secondary_enabled" 1
write_editor_scalar "$KA_WIZ_DIR/secondary_interval" 300
write_editor_scalar "$KA_WIZ_DIR/secondary_message" enabled
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
KA_F_STATUS=ACTIVE
KA_F_SEC_DONE=0
ka_wizard_effects CONFIGURE
assert_eq 'Secondary prompt armed: it fires once, 05:00 after saving.' "${KA_WIZ_EFFECTS[0]}" \
    'newly enabled secondary prompt is armed after save'
reset_effect_pair secondary-fired "$enabled_config"
write_editor_scalar "$KA_WIZ_DIR/secondary_interval" 300
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
KA_F_SEC_DONE=1
ka_wizard_effects CONFIGURE
assert_eq 'Secondary prompt armed: it fires once, 05:00 after saving.' "${KA_WIZ_EFFECTS[0]}" \
    'changed fired secondary prompt is re-armed for one new interval'
reset_effect_pair secondary-cap "$enabled_config"
write_editor_scalar "$KA_WIZ_DIR/secondary_interval" 300
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
KA_F_SEC_DONE=0
ka_wizard_effects CONFIGURE
assert_eq 'Secondary countdown: 11:40 left, capped at 05:00 on save.' "${KA_WIZ_EFFECTS[0]}" \
    'changed unfired secondary interval caps its countdown when needed'
reset_effect_pair secondary-paused "$base_config"
write_editor_scalar "$KA_WIZ_DIR/secondary_enabled" 1
write_editor_scalar "$KA_WIZ_DIR/secondary_interval" 300
write_editor_scalar "$KA_WIZ_DIR/secondary_message" enabled
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
KA_F_STATUS=PAUSED
ka_wizard_effects CONFIGURE
assert_eq 'Secondary prompt armed at 05:00; it counts once the target resumes.' \
    "${KA_WIZ_EFFECTS[0]}" 'PAUSED target wording says the secondary prompt counts after resume'
reset_effect_pair notifications-only "$base_config"
write_editor_scalar "$KA_WIZ_DIR/notifications" 1
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
ka_wizard_effects CONFIGURE
assert_eq 'Saving does not reset either countdown.' "${KA_WIZ_EFFECTS[0]}" \
    'notifications-only change says saving does not reset either countdown'

reset_effect_pair effect-order "$enabled_config"
write_editor_scalar "$KA_WIZ_DIR/main_interval" 600
write_editor_scalar "$KA_WIZ_DIR/secondary_interval" 300
write_editor_scalar "$KA_WIZ_DIR/messages/001" changed
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
KA_F_STATUS=ACTIVE
KA_WIZ_MAIN_LEFT=900
KA_WIZ_SEC_LEFT=700
ka_wizard_effects CONFIGURE
assert_eq 3 "${#KA_WIZ_EFFECTS[@]}" 'main, secondary, and rotation edits report three effects'
assert_eq 'Main countdown: 15:00 left, capped at 10:00 on save.' "${KA_WIZ_EFFECTS[0]}" \
    'effect list places the main countdown before rotation'
assert_eq 'Secondary countdown: 11:40 left, capped at 05:00 on save.' "${KA_WIZ_EFFECTS[1]}" \
    'effect list places the secondary countdown before rotation'
assert_eq 'Messages changed: the rotation restarts at message 1, and an owed Enter is dropped.' \
    "${KA_WIZ_EFFECTS[2]}" 'effect list places rotation after both countdown effects'

LIVE_UUID=tui-editor-live
KEEPALIVE_MONOTONIC_FILE="$TEST_TMP/monotonic"
export KEEPALIVE_MONOTONIC_FILE
export KEEPALIVE_SUSPEND_GAP=2
KA_TUI_INDEX_CACHE=''
KA_TUI_SORT_KEYS=()
KA_WIZ_LOADED_AT=0
KA_WIZ_LAST_DRAW=0
KA_WIZ_AWAY=0

write_live_snapshot ACTIVE 90 1500 1 80 600 0
set_editor_clock 100
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 90 "$KA_WIZ_MAIN_LEFT" 'live refresh starts ACTIVE main from the published remainder'
assert_eq 80 "$KA_WIZ_SEC_LEFT" 'live refresh starts ACTIVE secondary from the published remainder'
set_editor_clock 101
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 89 "$KA_WIZ_MAIN_LEFT" 'ACTIVE main extrapolates one second per frame'
assert_eq 79 "$KA_WIZ_SEC_LEFT" 'unfired ACTIVE secondary extrapolates one second per frame'
set_editor_clock 102
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 88 "$KA_WIZ_MAIN_LEFT" 'ACTIVE main extrapolates another second'

write_live_snapshot PAUSED 70 1500 1 50 600 0
set_editor_clock 200
ka_wizard_live_refresh "$LIVE_UUID"
set_editor_clock 201
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 70 "$KA_WIZ_MAIN_LEFT" 'PAUSED main remains frozen across a clock second'
assert_eq 50 "$KA_WIZ_SEC_LEFT" 'PAUSED secondary remains frozen across a clock second'

write_live_snapshot ACTIVE 80 1500 1 44 600 1
set_editor_clock 300
ka_wizard_live_refresh "$LIVE_UUID"
set_editor_clock 301
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 79 "$KA_WIZ_MAIN_LEFT" 'ACTIVE main continues while a secondary is done'
assert_eq 44 "$KA_WIZ_SEC_LEFT" 'completed one-shot secondary is not extrapolated'

KA_WIZ_LOADED_AT=0
KA_WIZ_LAST_DRAW=0
KA_TUI_INDEX_CACHE=''
write_live_snapshot ACTIVE 90 1500 1 70 600 0
set_editor_clock 400
ka_wizard_live_refresh "$LIVE_UUID"
set_editor_clock 401
ka_wizard_live_refresh "$LIVE_UUID"
set_editor_clock 405
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 89 "$KA_WIZ_MAIN_LEFT" 'a suspend-sized forward clock gap re-anchors without subtracting'
assert_eq 69 "$KA_WIZ_SEC_LEFT" 'secondary also preserves the remainder across a long gap'
set_editor_clock 404
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 89 "$KA_WIZ_MAIN_LEFT" 'a backward clock reading re-anchors without subtracting'

KA_WIZ_LOADED_AT=0
KA_WIZ_LAST_DRAW=0
write_live_snapshot ACTIVE 90 1500 1 70 600 0
set_editor_clock 500
ka_wizard_live_refresh "$LIVE_UUID"
KA_WIZ_AWAY=1
set_editor_clock 510
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 80 "$KA_WIZ_MAIN_LEFT" 'away flag suppresses the gap rule for the field screen frame'
assert_eq 60 "$KA_WIZ_SEC_LEFT" 'away frame still extrapolates ACTIVE secondary normally'
assert_eq 0 "$KA_WIZ_AWAY" 'away flag clears after one live-refresh frame'
set_editor_clock 511
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 79 "$KA_WIZ_MAIN_LEFT" 'normal gap handling resumes after the away frame'

write_live_snapshot ACTIVE 80 1500 1 60 600 0
set_editor_clock 600
ka_wizard_live_refresh "$LIVE_UUID"
set_editor_clock 601
ka_wizard_live_refresh "$LIVE_UUID"
write_live_snapshot ACTIVE 55 1500 1 33 600 0
set_editor_clock 602
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 55 "$KA_WIZ_MAIN_LEFT" 'changed index publication reloads the new main remainder'
assert_eq 33 "$KA_WIZ_SEC_LEFT" 'changed index publication reloads the new secondary remainder'

write_live_snapshot ACTIVE 40 1500 1 29 600 0
rm "$KEEPALIVE_MONOTONIC_FILE"
ka_wizard_live_refresh "$LIVE_UUID"
assert_eq 40 "$KA_WIZ_MAIN_LEFT" 'unreadable clock shows the published main remainder'
assert_eq 29 "$KA_WIZ_SEC_LEFT" 'unreadable clock shows the published secondary remainder'

KA_WIZ_ORIGINAL="$base_config"
KA_WIZ_DIR="$base_config"
ka_wizard_describe_all "$KA_WIZ_ORIGINAL" WAS
ka_wizard_describe_all "$KA_WIZ_DIR" NOW
set_editor_clock 700
write_live_snapshot ACTIVE 40 1500 1 29 600 0
KA_WIZ_LOADED_AT=0
KA_WIZ_LAST_DRAW=0
ka_wizard_live_refresh "$LIVE_UUID"
for width in 52 120; do
    for mode in default ascii; do
        if [[ $mode == ascii ]]; then KA_ASCII_MODE=1; else KA_ASCII_MODE=0; fi
        ka_tui_glyphs_init
        KA_TUI_COLS=$width
        for command in CREATE CONFIGURE; do
            KA_TUI_ACTIVE_VIEW=ka_wizard_editor_render
            KA_TUI_RESIZED=0
            frame_file="$TEST_TMP/frame-$width-$mode-$command"
            ka_wizard_editor_render "$LIVE_UUID" "$command" 0 >"$frame_file"
            assert_true "$command $mode editor frame fits $width columns and erases each line" \
                editor_frame_fits "$frame_file" "$width"
        done
    done
done

# Prime the real CONFIGURE path, then trace one frame after descriptions are cached.
KA_ASCII_MODE=1
ka_tui_glyphs_init
KA_TUI_COLS=120
KA_TUI_ACTIVE_VIEW=ka_wizard_editor_render
KA_TUI_RESIZED=0
KA_WIZ_LOADED_AT=0
KA_WIZ_LAST_DRAW=0
set_editor_clock 800
ka_wizard_live_refresh "$LIVE_UUID"
trace_file="$TEST_TMP/editor-trace"
frame_file="$TEST_TMP/editor-traced-frame"
exec {trace_fd}>"$trace_file"
BASH_XTRACEFD=$trace_fd
old_ps4=$PS4
PS4='+${BASHPID} '
set -x
ka_wizard_editor_render "$LIVE_UUID" CONFIGURE 0 >"$frame_file"
{ set +x; } 2>/dev/null
PS4=$old_ps4
unset BASH_XTRACEFD
exec {trace_fd}>&-
assert_true 'CONFIGURE renderer does not fork per frame after field descriptions are computed' \
    editor_trace_is_single_process "$trace_file"

# Role: Record helper process identities while returning deterministic field widths.
ka_tui_field_width_set() {
    local reserved=${1:-0} minimum=${2:-8} width
    printf '%s\n' "$BASHPID" >>"$HINT_PID_LOG"
    width=$((${KA_TUI_COLS:-80} - reserved))
    ((width < minimum)) && width=$minimum
    REPLY=$width
}

# Role: Record helper process identities while truncating the short hint like the real setter.
ka_tui_truncate_set() {
    local text=${1-} width=$2 ellipsis=${KA_G_ELL:-…}
    printf '%s\n' "$BASHPID" >>"$HINT_PID_LOG"
    if ((width <= 0)); then REPLY=''; return 0; fi
    if ((${#text} <= width)); then REPLY=$text; return 0; fi
    if ((width <= ${#ellipsis})); then REPLY=${text:0:width}; return 0; fi
    REPLY="${text:0:width - ${#ellipsis}}$ellipsis"
}

HINT_PID_LOG="$TEST_TMP/hint-pids"
KA_TUI_COLS=16
KA_ASCII_MODE=1
ka_tui_glyphs_init
: >"$HINT_PID_LOG"
hint_file="$TEST_TMP/hint-frame"
ka_wizard_hint 'up/down select    1-6 or Enter change    s save    Esc close' \
    'Enter change  s save  Esc close' >"$hint_file"
assert_true 'wizard hint truncation stays within a narrow terminal width' \
    editor_frame_fits "$hint_file" 16
assert_true 'wizard hint field helpers run in the current shell without a subshell' \
    editor_pid_log_is_current "$HINT_PID_LOG"

test_finish
