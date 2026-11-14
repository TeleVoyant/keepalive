#!/usr/bin/env bash
# Interactive TUI behaviour driven through a real pseudo-terminal.
#
# This is the only test that exercises key handling, navigation, and `set -e` escapes
# the way a user does. Three real defects once passed a fully green suite: unrecognized
# escape sequences exited the client, a key typed right after Escape was swallowed, and
# cancelling the wizard exited with status 1.
#
# It needs python3 for pty.fork(). The rest of the suite stays dependency-free, so this
# file skips cleanly when python3 is unavailable rather than failing the run.
set -Eeuo pipefail

# Run the entire PTY/service scenario as an ordinary user in root-owned CI containers.
# Re-executing before test_env_setup lets the unprivileged process create and own every
# fixture itself, matching the real service's deliberate root refusal.
if ((EUID == 0)); then
    if command -v runuser >/dev/null 2>&1 && id nobody >/dev/null 2>&1; then
        exec runuser -u nobody -- env PATH="$PATH" bash "${BASH_SOURCE[0]}"
    fi
    printf '# skip: an unprivileged account runner is required for the PTY service test\n'
    printf '# 0 assertions passed\n'
    exit 0
fi

source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup

if ! command -v python3 >/dev/null 2>&1; then
    printf '# skip: python3 is required to drive a pseudo-terminal\n'
    printf '# 0 assertions passed\n'
    exit 0
fi

DRIVER="$TEST_ROOT/tests/fixtures/pty-drive.py"
MOCK="$TEST_ROOT/tests/fixtures/qdbus-mock"

# Run a real process the classifier recognizes, rather than pointing the mock at this
# test's own PID: that only worked when an ancestor happened to be an AI client, which
# made the wizard assertions depend on the surrounding process tree.
bin="$TEST_TMP/bin"; mkdir -p "$bin"
cat >"$bin/claude" <<'FAKEAI'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$FAKE_AI_PID_FILE"
while :; do sleep 30; done
FAKEAI
chmod +x "$bin/claude"
ai_pid_file="$TEST_TMP/ai.pid"
env FAKE_AI_PID_FILE="$ai_pid_file" "$bin/claude" >/dev/null 2>&1 &
ai_wrapper=$!
for _ in {1..60}; do [[ -s $ai_pid_file ]] && break; sleep 0.05; done

export KEEPALIVE_QDBUS="$MOCK"
export FAKE_PID_FILE="$ai_pid_file"
export FAKE_UUID='12345678-1234-4123-8123-123456789abc'
export KEEPALIVE_DISCOVERY_INTERVAL=1 KEEPALIVE_HEALTH_INTERVAL=1
# This file launches many short-lived clients against one daemon; a loaded machine can
# push a round trip past the default budget, which would look like an unreachable service.
export KEEPALIVE_RESPONSE_TIMEOUT_MS=20000

service_log="$TEST_TMP/service.log"
"$TEST_ROOT/keepalive" --service >"$service_log" 2>&1 &
service_pid=$!

# Role: Stop the background daemon started for this test file.
cleanup_pty_tests() {
    kill "$service_pid" 2>/dev/null || true
    wait "$service_pid" 2>/dev/null || true
    [[ -s ${ai_pid_file:-} ]] && kill "$(cat "$ai_pid_file")" 2>/dev/null || true
    kill "${ai_wrapper:-0}" 2>/dev/null || true
    return 0
}
trap cleanup_pty_tests EXIT

for _ in {1..80}; do [[ -p $XDG_RUNTIME_DIR/keepalive/control.fifo ]] && break; sleep 0.05; done
assert_true 'daemon is listening before the TUI starts' test -p "$XDG_RUNTIME_DIR/keepalive/control.fifo"

# The wizard assertions need a genuinely discovered AVAILABLE row to open onto.
"$TEST_ROOT/keepalive" refresh >/dev/null 2>&1 || true
listing=$("$TEST_ROOT/keepalive" list 2>/dev/null || true)
assert_true 'a recognized AI session is discovered before the TUI assertions' \
    grep -q AVAILABLE <<<"$listing"

# Role: Run the TUI with a scripted key sequence and report only the exit status.
# The shared PTY driver waits for fresh output and the terminal mode expected by each
# input, including canonical buffering for line prompts.
tui_exit() {
    local keys=$1 settle=${2:-0.3} result
    # The second manager frame is an output barrier after startup, so the first real
    # action is not sent during the client's initial terminal-mode transition.
    result=$(python3 "$DRIVER" 110 40 "$settle" "@navigate,@navigate,${keys}" -- "$TEST_ROOT/keepalive" 2>&1 >/dev/null |
        sed -n 's/^exit=//p')
    # Retry only START-TIMEOUT, which means no input was sent and the client never reached
    # its first manager frame. A plain TIMEOUT follows the entire sequence: Configure may
    # already have committed before a final quit key was missed, so replaying it can change
    # the state that later assertions inspect.
    #
    # This cannot mask the defect these assertions exist for: a key that wrongly exits the
    # client shows up as WAIT-TIMEOUT on the following redraw wait, which is never retried,
    # and a genuinely broken quit key times out on both attempts.
    if [[ $result == START-TIMEOUT:* ]]; then
        result=$(python3 "$DRIVER" 110 40 "$settle" "@navigate,@navigate,${keys}" -- "$TEST_ROOT/keepalive" 2>&1 >/dev/null |
            sed -n 's/^exit=//p')
    fi
    printf '%s' "$result"
}

# Every one of these key classes used to quit the client, because an unrecognized escape
# sequence decoded as a bare Escape and Escape quits the manager.
#
# One session, not one per key: each key is followed by a wait for a fresh manager draw,
# so if any of them exits the client the output stops and the driver reports the missed
# synchronisation. Launching a client per key instead put enough load on the shared
# daemon to make the assertions intermittently time out.
survive_keys=''
for key in RIGHT LEFT F1 F5 PASTE TAB HOME END PGUP PGDN; do
    survive_keys+="$key,@navigate,"
done
assert_eq 0 "$(tui_exit "${survive_keys}q")" \
    'no arrow, function, keypad, or bracketed-paste key exits the manager'

assert_eq 0 "$(tui_exit 'q')" 'q closes the manager cleanly'
assert_eq 0 "$(tui_exit 'ESC')" 'a bare Escape closes the manager cleanly'
assert_eq 0 "$(tui_exit 'DOWN,UP,@navigate,q')" 'navigation keys do not disturb the exit path'
assert_eq 0 "$(tui_exit 'z,x,@navigate,q')" 'unmapped characters are ignored'
assert_eq 0 "$(tui_exit 'r,@navigate,q')" 'a refresh request returns to the manager'

# Escape followed immediately by another key must keep both; the second used to be lost.
assert_eq 0 "$(tui_exit 'ESC,q' 0.02)" 'Escape and a fast following key are both delivered'

# Role: Drive a PTY to a checked capture barrier and render its final screen for assertions.
capture_tui_screen() {
    local name=$1 cols=$2 rows=$3 keys=$4 rc=0
    shift 4
    python3 "$DRIVER" "$cols" "$rows" 0.12 "$keys" -- "$@" \
        >"$TEST_TMP/$name.raw" 2>"$TEST_TMP/$name.status" || rc=$?
    assert_eq 0 "$rc" "$name PTY capture driver exits successfully"
    assert_eq CAPTURED "$(sed -n 's/^exit=//p' "$TEST_TMP/$name.status")" \
        "$name PTY capture stops at its output barrier"
    python3 "$TEST_ROOT/tests/fixtures/vt-render.py" "$TEST_TMP/$name.raw" "$cols" "$rows" \
        >"$TEST_TMP/$name.screen"
}

# Role: Check captured terminal output by display cells after removing ANSI control sequences.
rendered_lines_fit() {
    local path=$1 cols=$2
    python3 - "$path" "$cols" <<'PY'
import pathlib
import re
import sys
import unicodedata

ansi = re.compile(r'\x1b\[[0-?]*[ -/]*[@-~]')
path, limit = sys.argv[1], int(sys.argv[2])
for number, raw in enumerate(pathlib.Path(path).read_text().splitlines(), 1):
    line = ansi.sub('', raw).replace('\x1b(B', '')
    width = sum(
        0 if unicodedata.combining(char) or unicodedata.category(char) in {'Mn', 'Me', 'Cf'}
        else 2 if unicodedata.east_asian_width(char) in {'W', 'F'} else 1
        for char in line
    )
    if width > limit:
        print(f'line {number} is {width} cells, terminal is {limit}: {line!r}', file=sys.stderr)
        sys.exit(1)
PY
}

# Role: Read one field from the isolated daemon checkpoint after a successful Configure request.
target_state_value() {
    local field=$1
    awk -F '\t' -v field="$field" '$1 == field { print $2; found=1; exit } END { if (!found) exit 1 }' \
        "$XDG_RUNTIME_DIR/keepalive/targets/$FAKE_UUID/state.tsv"
}

# Opening Create from AVAILABLE shows all six fields at the supported minimum size.
capture_tui_screen create_52 52 20 '@j/k move,@j/k move,1,@Settings,@s save,CAPTURE' "$TEST_ROOT/keepalive"
screen="$TEST_TMP/create_52.screen"
for field in 'Messages' 'Main interval' 'Secondary prompt' 'Notifications' 'Delivery' 'Save as default'; do
    assert_contains "$screen" "$field" "Create settings list includes $field"
done
assert_true 'default 52x20 Create output has no wrapped or overrun lines' \
    rendered_lines_fit "$TEST_TMP/create_52.raw" 52

# The same list remains within the terminal width across the presentation tiers.
capture_tui_screen create_ascii 52 20 \
    '@j/k move,@j/k move,1,@Settings,@s save,CAPTURE' "$TEST_ROOT/keepalive" --ascii
capture_tui_screen create_no_icons 52 20 \
    '@j/k move,@j/k move,1,@Settings,@s save,CAPTURE' "$TEST_ROOT/keepalive" --no-icons
capture_tui_screen create_no_color 52 20 \
    '@j/k move,@j/k move,1,@Settings,@s save,CAPTURE' env NO_COLOR=1 "$TEST_ROOT/keepalive"
for style in ascii no_icons no_color; do
    assert_true "$style 52x20 Create output has no wrapped or overrun lines" \
        rendered_lines_fit "$TEST_TMP/create_$style.raw" 52
    for field in 'Messages' 'Main interval' 'Secondary prompt' 'Notifications' 'Delivery' 'Save as default'; do
        assert_contains "$TEST_TMP/create_$style.screen" "$field" \
            "$style 52x20 settings list includes $field"
    done
done

# At 52x19 the editor reports its minimum size instead of drawing a partial frame.
capture_tui_screen too_small 52 19 \
    '@j/k move,@j/k move,1,@Terminal too small,CAPTURE' "$TEST_ROOT/keepalive"
assert_contains "$TEST_TMP/too_small.screen" 'Terminal too small.' 'short editor shows the size notice'
assert_contains "$TEST_TMP/too_small.screen" 'Resize to at least 52x20' 'size notice gives the editor minimum'

# Esc without edits returns immediately; a field's Esc returns to the same list unchanged.
assert_eq 0 "$(tui_exit '1,@Settings,ESC,@navigate,q')" \
    'Esc closes an unchanged Create editor without a discard prompt'
capture_tui_screen digit_main 110 40 '@navigate,@navigate,1,@Settings,2,@Main interval,CAPTURE' "$TEST_ROOT/keepalive"
assert_contains "$TEST_TMP/digit_main.screen" 'Main interval' 'digit 2 opens the Main interval field editor'
assert_eq 0 "$(tui_exit '1,@Settings,2,@Main interval,ESC,@Settings,ESC,@navigate,q')" \
    'Esc in Main interval returns unchanged to the list, then closes without confirmation'

# A changed row displays its original and new values; n keeps editing and y discards.
capture_tui_screen profile_marker 110 40 \
    '@navigate,@navigate,1,@Settings,6,@no,CAPTURE' "$TEST_ROOT/keepalive"
assert_contains "$TEST_TMP/profile_marker.screen" 'yes → no, this keep-alive only' \
    'Save as default shows before and after values'
assert_contains "$TEST_TMP/profile_marker.screen" '*' 'changed field has a marker'
assert_eq 0 "$(tui_exit '1,@Settings,6,@no,ESC,@Unsaved changes,n,@Settings,ESC,@Unsaved changes,y,@navigate,q')" \
    'n keeps an edited list open and y discards its edits'

# Create with a changed interval and enabled secondary prompt, using the default profile policy.
assert_eq 0 "$(tui_exit '1,@Settings,2,@Main interval,2,ENTER,@Settings,3,@Secondary prompt,2,ENTER,@Secondary message,ENTER,@Secondary interval in minutes,ENTER,@Settings,s,@Keep-alive created.,@navigate,q')" \
    's creates the keep-alive and shows its success toast'
assert_eq 900 "$(cat "$XDG_CONFIG_HOME/keepalive/profile/main_interval")" \
    'Create saves the edited interval to the default profile when selected'
assert_eq 1 "$(cat "$XDG_CONFIG_HOME/keepalive/profile/secondary_enabled")" \
    'Create saves the enabled secondary setting to the default profile'

# Adding a message still leaves one key hint and one copy of the message on screen.
# Exercise the same field sub-editor from Configure after Create has made the target ACTIVE.
capture_tui_screen message_add 100 30 \
    '@navigate,@navigate,1,@ACTIVE,c,@Settings,1,@Main message rotation,a,@New message,hello world,ENTER,@hello world,CAPTURE' \
    "$TEST_ROOT/keepalive"
screen=$(cat "$TEST_TMP/message_add.screen")
assert_eq 1 "$(grep -c 'a add' <<<"$screen" || true)" 'message editor key hint is drawn exactly once'
assert_eq 1 "$(grep -c 'hello world' <<<"$screen" || true)" 'new message is drawn exactly once'
assert_eq 0 "$(grep -c 'New message:' <<<"$screen" || true)" 'message prompt is erased after adding a message'

# A longer Configure interval must preserve the running countdown instead of resetting it.
assert_eq 0 "$(tui_exit '1,@ACTIVE,c,@Settings,2,@Main interval,4,ENTER,@Custom interval in minutes,30,@30,ENTER,@Settings,6,@no,s,@Settings saved.,@Timers,ESC,@navigate,q')" \
    'Configure from detail saves and returns with the updated toast'
assert_eq 1800 "$(target_state_value main_interval)" 'Configure stores the longer main interval'
remaining=$(target_state_value main_remaining)
assert_true 'longer interval preserves the smaller current main countdown' test "$remaining" -gt 800
assert_true 'preserved countdown is below the new full interval' test "$remaining" -lt 1800
assert_eq 900 "$(cat "$XDG_CONFIG_HOME/keepalive/profile/main_interval")" \
    'Save as default off leaves the profile unchanged during Configure'

# Configure shows both live rows and previews a cap before saving a shorter main interval.
capture_tui_screen configure_cap 110 40 \
    '@navigate,@navigate,1,@ACTIVE,c,@Settings,2,@Main interval,4,ENTER,@Custom interval in minutes,1,@1,ENTER,@capped at 01:00,@s save,CAPTURE' \
    "$TEST_ROOT/keepalive"
assert_contains "$TEST_TMP/configure_cap.screen" 'MAIN' 'Configure list shows the main countdown row'
assert_contains "$TEST_TMP/configure_cap.screen" 'SECONDARY' 'Configure list shows the enabled secondary countdown row'
assert_contains "$TEST_TMP/configure_cap.screen" 'capped at 01:00 on save' 'shorter interval previews the main countdown cap'

# Saving that cap is accepted, leaves remaining time at or below the cap, and keeps the secondary timer.
assert_eq 0 "$(tui_exit '1,@ACTIVE,c,@Settings,2,@Main interval,4,ENTER,@Custom interval in minutes,1,@1,ENTER,@capped at 01:00,6,@no,s,@Settings saved.,@Timers,ESC,@navigate,q')" \
    'shorter Configure save shows the success toast and returns to the manager'
assert_eq 60 "$(target_state_value main_interval)" 'shorter Configure stores a one-minute main interval'
remaining=$(target_state_value main_remaining)
assert_true 'main countdown is capped at the new interval' test "$remaining" -gt 0
assert_true 'main countdown does not exceed the new interval' test "$remaining" -le 60
assert_eq 600 "$(target_state_value secondary_interval)" 'unchanged secondary interval stays configured'
assert_eq 0 "$(target_state_value secondary_done)" 'unchanged secondary one-shot remains armed'
assert_eq 900 "$(cat "$XDG_CONFIG_HOME/keepalive/profile/main_interval")" \
    'Save as default off remains honored by the shorter Configure save'

test_finish
