#!/usr/bin/env bash
# Minimal dependency-free test helpers for Keep Alive Manager.
set -Eeuo pipefail

TEST_ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
TEST_COUNT=0
TEST_FAIL=0

# Role: Print a TAP-like success/failure assertion for exact string equality.
assert_eq() {
    local expected=$1 actual=$2
    local message=${3:-"expected '$expected', got '$actual'"}
    ((TEST_COUNT += 1))
    if [[ $expected == "$actual" ]]; then
        printf 'ok %d - %s\n' "$TEST_COUNT" "$message"
    else
        printf 'not ok %d - %s (expected=%q actual=%q)\n' "$TEST_COUNT" "$message" "$expected" "$actual"
        ((TEST_FAIL += 1))
    fi
}

# Role: Assert that a command/function invocation returns success.
assert_true() {
    local message=$1; shift
    ((TEST_COUNT += 1))
    if "$@"; then printf 'ok %d - %s\n' "$TEST_COUNT" "$message"; else printf 'not ok %d - %s\n' "$TEST_COUNT" "$message"; ((TEST_FAIL += 1)); fi
}

# Role: Assert that a command/function invocation returns failure.
assert_false() {
    local message=$1; shift
    ((TEST_COUNT += 1))
    if "$@"; then printf 'not ok %d - %s\n' "$TEST_COUNT" "$message"; ((TEST_FAIL += 1)); else printf 'ok %d - %s\n' "$TEST_COUNT" "$message"; fi
}

# Role: Assert that a regular file exists.
assert_file() {
    local path=$1
    local message=${2:-"file exists: $path"}
    ((TEST_COUNT += 1))
    if [[ -f $path ]]; then printf 'ok %d - %s\n' "$TEST_COUNT" "$message"; else printf 'not ok %d - %s\n' "$TEST_COUNT" "$message"; ((TEST_FAIL += 1)); fi
}

# Role: Assert that a file contains a fixed literal substring.
assert_contains() {
    local path=$1 needle=$2
    local message=${3:-"$path contains $needle"}
    ((TEST_COUNT += 1))
    if grep -Fq -- "$needle" "$path"; then printf 'ok %d - %s\n' "$TEST_COUNT" "$message"; else printf 'not ok %d - %s\n' "$TEST_COUNT" "$message"; ((TEST_FAIL += 1)); fi
}

# Role: Create isolated HOME/XDG directories so tests never touch the real user profile.
test_env_setup() {
    TEST_TMP=$(mktemp -d)
    export HOME="$TEST_TMP/home"
    export XDG_CONFIG_HOME="$TEST_TMP/config"
    export XDG_RUNTIME_DIR="$TEST_TMP/runtime"
    export XDG_STATE_HOME="$TEST_TMP/state"
    # Unit/integration tests opt into mocked Orca explicitly; never attach to a developer's
    # live Orca runtime merely because orca-ide happens to be on PATH.
    export KEEPALIVE_ORCA_ENABLED=0
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME"
}

# Role: Source all non-TUI runtime modules in production order for unit tests.
source_core() {
    source "$TEST_ROOT/lib/common.sh"
    source "$TEST_ROOT/lib/xdg.sh"
    source "$TEST_ROOT/lib/qdbus.sh"
    source "$TEST_ROOT/lib/classifier.sh"
    source "$TEST_ROOT/lib/konsole.sh"
    source "$TEST_ROOT/lib/orca.sh"
    source "$TEST_ROOT/lib/transport.sh"
    source "$TEST_ROOT/lib/profile.sh"
    source "$TEST_ROOT/lib/logging.sh"
    source "$TEST_ROOT/lib/notifications.sh"
    source "$TEST_ROOT/lib/state.sh"
    source "$TEST_ROOT/lib/scheduler.sh"
    source "$TEST_ROOT/lib/ipc.sh"
    ka_xdg_init
    ka_ensure_runtime_dirs
    ka_ensure_config_dirs
}

# Role: Print a target's runtime directory for tests that need it inline.
# Production code reads REPLY directly; this wrapper exists only so test expressions stay
# readable, without reintroducing a printing variant on the daemon's hot paths.
target_dir() {
    ka_state_target_dir "$1"
    printf '%s' "$REPLY"
}

# Role: Remove isolated temporary data and return a test file's accumulated status.
test_finish() {
    local rc=$TEST_FAIL
    rm -rf -- "${TEST_TMP:-}" 2>/dev/null || true
    if ((rc == 0)); then printf '# %d assertions passed\n' "$TEST_COUNT"; else printf '# %d/%d assertions failed\n' "$rc" "$TEST_COUNT"; fi
    return "$rc"
}
