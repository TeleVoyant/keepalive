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
# Every sequence waits for the manager to be drawn first, then waits for it again before
# quitting. Sending keys on a fixed delay races the client's startup and its redraws,
# which made these assertions intermittently report a timeout.
tui_exit() {
    local keys=$1 settle=${2:-0.3} result
    result=$(python3 "$DRIVER" 110 40 "$settle" "@navigate,${keys}" -- "$TEST_ROOT/keepalive" 2>&1 >/dev/null |
        sed -n 's/^exit=//p')
    # Retry only a plain exit timeout, and only once. Bash's `read -n1` reconfigures the
    # terminal for every keystroke, and tcsetattr can discard input arriving in that
    # window; a human types far too slowly to hit it, a scripted driver occasionally does,
    # and the dropped key is always the final quit.
    #
    # A client that never drew at all reports START-TIMEOUT and is retried for the same
    # reason: it says nothing about the keys.
    #
    # This cannot mask the defect these assertions exist for: a key that wrongly exits the
    # client shows up as WAIT-TIMEOUT on the following redraw wait, which is never retried,
    # and a genuinely broken quit key times out on both attempts.
    if [[ $result == TIMEOUT || $result == START-TIMEOUT:* ]]; then
        result=$(python3 "$DRIVER" 110 40 "$settle" "@navigate,${keys}" -- "$TEST_ROOT/keepalive" 2>&1 >/dev/null |
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

# A cancelled wizard is normal navigation, not a client failure. Under `set -e` the
# non-zero return used to escape the loop body and terminate the TUI.
assert_eq 0 "$(tui_exit '@navigate,1,@a add,ESC,@navigate,q')" \
    'cancelling the wizard at step one returns to the manager'
assert_eq 0 "$(tui_exit '@navigate,1,@a add,ENTER,@Main interval,ENTER,@Secondary prompt,ESC,@Main interval,ESC,@a add,ESC,@navigate,q')" \
    'backing out through wizard steps returns to the manager'

# The rendered screen, not the byte stream, is what shows stale tails. Adding a wizard
# message grows the frame by a line, so every line below it is redrawn with different
# content; the key-hint footer used to appear twice.
VT="$TEST_ROOT/tests/fixtures/vt-render.py"
capture="$TEST_TMP/wizard-add.cap"
capture_status="$TEST_TMP/wizard-add.status"
# Wait for each screen instead of guessing with sleeps, or the typed message races the
# wizard's first draw and lands nowhere. CAPTURE stops the child after the final barrier,
# so this assertion never waits for the driver's normal 40-second timeout.
capture_rc=0
python3 "$DRIVER" 100 30 0.4 '@navigate,1,@a add,a,@New message,hello world,ENTER,@hello world,CAPTURE' \
    -- "$TEST_ROOT/keepalive" >"$capture" 2>"$capture_status" || capture_rc=$?
assert_eq 0 "$capture_rc" 'wizard capture driver exits successfully'
assert_eq CAPTURED "$(sed -n 's/^exit=//p' "$capture_status")" \
    'wizard capture driver reports a checked CAPTURED status'
screen=$(python3 "$VT" "$capture" 100 30)
assert_eq 1 "$(grep -c 'a add' <<<"$screen")" 'the wizard key hint is drawn exactly once after adding a message'
assert_eq 1 "$(grep -c 'hello world' <<<"$screen")" 'the newly added message appears exactly once'
assert_eq 0 "$(grep -c 'New message:' <<<"$screen")" 'the prompt line is erased once the frame redraws'

test_finish
