#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source "$TEST_ROOT/lib/common.sh"
source "$TEST_ROOT/lib/xdg.sh"
source "$TEST_ROOT/lib/qdbus.sh"

socket_pid=''

# Role: Stop the temporary Unix-socket fixture if this test exits early.
cleanup_portability() {
    [[ $socket_pid =~ ^[0-9]+$ ]] || return 0
    kill "$socket_pid" 2>/dev/null || true
    wait "$socket_pid" 2>/dev/null || true
}
trap cleanup_portability EXIT

per_user="$TEST_TMP/per-user"
mkdir -p "$per_user"
chmod 700 "$per_user"
export KEEPALIVE_PER_USER_RUNTIME="$per_user"

export XDG_RUNTIME_DIR='relative/runtime'
assert_false 'relative XDG_RUNTIME_DIR is unsafe' ka_runtime_candidate_is_safe "$XDG_RUNTIME_DIR"
ka_xdg_resolve_runtime_base
assert_eq "$per_user" "$KA_RUNTIME_BASE" 'relative XDG runtime falls back to per-user'
assert_eq per-user "$KA_RUNTIME_SOURCE" 'relative runtime records per-user source'
assert_eq 'relative/runtime' "$KA_RUNTIME_REJECTED" 'rejected relative runtime is recorded'

foreign="$TEST_TMP/foreign"
mkdir -p "$foreign"
if ((EUID == 0)); then chown 65534:65534 "$foreign"; else foreign=/proc; fi
export XDG_RUNTIME_DIR="$foreign"
assert_false 'foreign XDG_RUNTIME_DIR is unsafe' ka_runtime_candidate_is_safe "$XDG_RUNTIME_DIR"
ka_xdg_resolve_runtime_base
assert_eq "$per_user" "$KA_RUNTIME_BASE" 'foreign runtime falls back to per-user'

mkdir -p "$TEST_TMP/real/child"
ln -s "$TEST_TMP/real" "$TEST_TMP/parent-link"
export XDG_RUNTIME_DIR="$TEST_TMP/parent-link/child"
assert_false 'parent-symlink XDG_RUNTIME_DIR is unsafe' ka_runtime_candidate_is_safe "$XDG_RUNTIME_DIR"
ka_xdg_resolve_runtime_base
assert_eq "$per_user" "$KA_RUNTIME_BASE" 'parent-symlink runtime falls back to per-user'

default_per_user="/run/user/$UID"
if [[ -d $default_per_user && -O $default_per_user && ! -L $default_per_user \
    && $(readlink -f -- "$default_per_user") == "$default_per_user" ]]; then
    unset XDG_RUNTIME_DIR KEEPALIVE_PER_USER_RUNTIME
    ka_xdg_resolve_runtime_base
    assert_eq "$default_per_user" "$KA_RUNTIME_BASE" 'default /run/user/$UID fallback is selected'
    assert_eq per-user "$KA_RUNTIME_SOURCE" 'default /run/user fallback records source'
    export KEEPALIVE_PER_USER_RUNTIME="$per_user"
fi

HOME=relative
unset XDG_CONFIG_HOME
rc=0
ka_xdg_init 2>/dev/null || rc=$?
assert_eq 1 "$rc" 'relative HOME is rejected without XDG_CONFIG_HOME'
assert_eq 'HOME must be an absolute path when XDG_CONFIG_HOME is unset' "$KA_LAST_ERROR" \
    'HOME rejection explains why'

export HOME="$TEST_TMP/home" XDG_CONFIG_HOME=relative
rc=0
ka_xdg_init 2>/dev/null || rc=$?
assert_eq 1 "$rc" 'relative XDG_CONFIG_HOME is rejected'
assert_eq 'XDG_CONFIG_HOME must be an absolute path' "$KA_LAST_ERROR" \
    'config rejection explains why'

unset XDG_CONFIG_HOME
ka_xdg_init
assert_eq "$HOME/.config" "$KA_CONFIG_HOME" 'absolute HOME supplies config path'
unset HOME
export XDG_CONFIG_HOME="$TEST_TMP/absolute-config"
ka_xdg_init
assert_eq "$TEST_TMP/absolute-config" "$KA_CONFIG_HOME" 'absolute config works without HOME'

ka_dbus_escape_address_value '/tmp/runtime with #percent%=,;?'
assert_eq '/tmp/runtime%20with%20%23percent%25%3D%2C%3B%3F' "$REPLY" \
    'D-Bus address values percent-escape reserved bytes'
# Byte values are masked in the escaper, so this holds on musl as well as glibc.
ka_dbus_escape_address_value '/tmp/é'
assert_eq '/tmp/%C3%A9' "$REPLY" 'D-Bus address escaping operates on UTF-8 bytes'

export DBUS_SESSION_BUS_ADDRESS='unix:path=/explicit/bus%2Ckeep'
KA_RUNTIME_BASE="$TEST_TMP/runtime with space"
ka_dbus_prepare_session_address
assert_eq 'unix:path=/explicit/bus%2Ckeep' "$DBUS_SESSION_BUS_ADDRESS" \
    'explicit D-Bus address is preserved'

if command -v python3 >/dev/null 2>&1; then
    socket_root="$TEST_TMP/runtime #%"
    mkdir -p "$socket_root"
    bus="$socket_root/bus"
    socket_error="$TEST_TMP/socket-fixture.err"
    python3 - "$bus" 2>"$socket_error" <<'PY' &
import socket
import sys
import time

s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(1)
try:
    time.sleep(30)
finally:
    s.close()
PY
    socket_pid=$!
    for _ in {1..50}; do
        [[ -S $bus ]] && break
        kill -0 "$socket_pid" 2>/dev/null || break
        sleep 0.02
    done
    if [[ -S $bus ]]; then
        assert_true 'temporary Unix socket fixture exists' test -S "$bus"
        unset DBUS_SESSION_BUS_ADDRESS
        KA_RUNTIME_BASE=$socket_root
        ka_dbus_prepare_session_address
        assert_eq "unix:path=$TEST_TMP/runtime%20%23%25/bus" "$DBUS_SESSION_BUS_ADDRESS" \
            'derived D-Bus address escapes the selected runtime path'
        cleanup_portability
        socket_pid=''
    else
        wait "$socket_pid" 2>/dev/null || true
        socket_pid=''
        socket_reason=$(tr '\n' ' ' <"$socket_error")
        socket_reason=${socket_reason:-'host does not permit Unix-domain socket fixtures'}
        test_skip 'temporary Unix socket fixture exists' "$socket_reason"
        test_skip 'derived D-Bus address escapes the selected runtime path' "$socket_reason"
    fi
fi

# Role: Run one informational CLI mode with all HOME and XDG inputs removed.
run_without_home() {
    env -u HOME -u XDG_CONFIG_HOME -u XDG_RUNTIME_DIR -u XDG_STATE_HOME \
        "$TEST_ROOT/keepalive" "$@"
}

# Read from the entrypoint rather than spelled out, so a release bump stays mechanical.
declared_version=$(sed -n "s/^KEEPALIVE_VERSION='\(.*\)'/\1/p" "$TEST_ROOT/keepalive")

for mode in version help icons; do
    case $mode in
        version) args=(--version); needle="keepalive $declared_version" ;;
        help) args=(--help); needle='Keep Alive Manager' ;;
        icons) args=(--icons-test); needle='Keep Alive Nerd Font test' ;;
    esac
    rc=0
    run_without_home "${args[@]}" >"$TEST_TMP/$mode.out" 2>"$TEST_TMP/$mode.err" || rc=$?
    assert_eq 0 "$rc" "HOME-unset $mode exits successfully"
    assert_contains "$TEST_TMP/$mode.out" "$needle" "HOME-unset $mode prints information"
    assert_eq '' "$(<"$TEST_TMP/$mode.err")" "HOME-unset $mode has no error"
done

for mode in version help icons; do
    case $mode in
        version) args=(--no-icons --version); needle="keepalive $declared_version" ;;
        help) args=(--ascii --help); needle='Keep Alive Manager' ;;
        icons) args=(--no-color --icons-test); needle='Keep Alive Nerd Font test' ;;
    esac
    rc=0
    run_without_home "${args[@]}" >"$TEST_TMP/flag-$mode.out" \
        2>"$TEST_TMP/flag-$mode.err" || rc=$?
    assert_eq 0 "$rc" "presentation flag before $mode succeeds without HOME"
    assert_contains "$TEST_TMP/flag-$mode.out" "$needle" \
        "presentation flag before $mode keeps information output"
    assert_eq '' "$(<"$TEST_TMP/flag-$mode.err")" \
        "presentation flag before $mode does not initialize XDG"
done

trap - EXIT
test_finish
