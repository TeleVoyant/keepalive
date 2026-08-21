#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup

work="$TEST_TMP/work/Avela"
bin="$TEST_TMP/bin"
mkdir -p "$work" "$bin"
pid_file="$TEST_TMP/ai.pid"
uuid_file="$TEST_TMP/uuid"
send_log="$TEST_TMP/send.log"
send_fail_file="$TEST_TMP/send.fail"
service_log="$TEST_TMP/service.log"
old_uuid='aaaaaaaa-1111-4222-8333-bbbbbbbbbbbb'
new_uuid='cccccccc-4444-4555-8666-dddddddddddd'
printf '%s\n' "$old_uuid" >"$uuid_file"

cat >"$bin/claude" <<'FAKEAI'
#!/usr/bin/env bash
printf '%s\n' "$$" >"$FAKE_AI_PID_FILE"
while :; do sleep 30; done
FAKEAI
chmod +x "$bin/claude"

# Role: Run one command as the normal test account, dropping root to nobody in root-based CI.
run_test_user() {
    if ((EUID == 0)); then
        runuser -u nobody -- "$@"
    else
        "$@"
    fi
}

# Role: Build the common environment array used by daemon and client subprocesses.
service_env() {
    printf '%s\0' \
        "HOME=$HOME" "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" "XDG_STATE_HOME=$XDG_STATE_HOME" \
        "KEEPALIVE_QDBUS=$TEST_ROOT/tests/fixtures/qdbus-mock" "FAKE_PID_FILE=$pid_file" "FAKE_UUID_FILE=$uuid_file" \
        "FAKE_SEND_LOG=$send_log" "FAKE_SEND_FAIL_FILE=$send_fail_file" \
        "KEEPALIVE_DISCOVERY_INTERVAL=1" "KEEPALIVE_HEALTH_INTERVAL=1" "PATH=/usr/bin:/bin"
}

# Role: Start a recognized fake Claude process in the requested project directory and wait for its PID file.
start_fake_ai() {
    rm -f -- "$pid_file"
    if ((EUID == 0)); then
        runuser -u nobody -- env FAKE_AI_PID_FILE="$pid_file" bash -c "cd '$work' && exec '$bin/claude'" >/dev/null 2>&1 &
    else
        env FAKE_AI_PID_FILE="$pid_file" bash -c "cd '$work' && exec '$bin/claude'" >/dev/null 2>&1 &
    fi
    local wrapper=$! i
    for ((i=0; i<50; i++)); do [[ -s $pid_file ]] && break; sleep 0.05; done
    [[ -s $pid_file ]] || return 1
    KA_FAKE_AI_PID=$(cat "$pid_file")
    KA_FAKE_AI_WRAPPER=$wrapper
}

# Role: Execute the public keepalive CLI with the exact isolated integration-test environment.
run_keepalive() {
    local -a envs=()
    while IFS= read -r -d '' item; do envs+=("$item"); done < <(service_env)
    run_test_user env "${envs[@]}" "$TEST_ROOT/keepalive" "$@"
}

# Role: Submit a CREATE request through production IPC without driving the interactive wizard.
create_target_via_ipc() {
    local uuid=$1 helper="$TEST_TMP/create-helper.sh"
    cat >"$helper" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$1; UUID=$2
source "$ROOT/lib/common.sh"; source "$ROOT/lib/xdg.sh"; source "$ROOT/lib/profile.sh"; source "$ROOT/lib/ipc.sh"
ka_xdg_init; ka_ensure_runtime_dirs; ka_profile_init_defaults
id=$(ka_ipc_new_request CREATE "$UUID")
req=$(ka_ipc_request_dir "$id")
mkdir -p "$req/config"
ka_profile_copy_to_request "$req/config"
ka_write_scalar "$req/config/main_interval" 120
ka_ipc_signal_request "$id"
ka_ipc_wait_response "$id"
HELPER
    chmod +x "$helper"
    local -a envs=() item
    while IFS= read -r -d '' item; do envs+=("$item"); done < <(service_env)
    run_test_user env "${envs[@]}" bash "$helper" "$TEST_ROOT" "$uuid"
}

# Role: Stop background service/AI processes created by this integration test.
cleanup_integration() {
    local pid=''
    if [[ -r $XDG_RUNTIME_DIR/keepalive/service.state ]]; then
        pid=$(awk -F '\t' '$1=="pid"{print $2; exit}' "$XDG_RUNTIME_DIR/keepalive/service.state" || true)
        [[ $pid =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    fi
    [[ ${KA_FAKE_AI_PID:-} =~ ^[0-9]+$ ]] && kill "$KA_FAKE_AI_PID" 2>/dev/null || true
    [[ ${KA_FAKE_AI_WRAPPER:-} =~ ^[0-9]+$ ]] && kill "$KA_FAKE_AI_WRAPPER" 2>/dev/null || true
}
trap cleanup_integration EXIT

# nobody must own the isolated tree when CI itself is root.
if ((EUID == 0)); then chown -R nobody:nogroup "$TEST_TMP"; chmod 755 "$TEST_TMP"; fi

start_fake_ai

# Start the real daemon core directly; socket activation is separately verified statically.
mapfile -d '' -t ENV_ARGS < <(service_env)
run_test_user env "${ENV_ARGS[@]}" "$TEST_ROOT/keepalive" --service >"$service_log" 2>&1 &
service_wrapper=$!
for i in {1..80}; do [[ -p $XDG_RUNTIME_DIR/keepalive/control.fifo ]] && break; sleep 0.05; done
assert_true 'background daemon creates control FIFO' test -p "$XDG_RUNTIME_DIR/keepalive/control.fifo"

list=$(run_keepalive list)
[[ $list == *Claude* && $list == *Avela* && $list == *AVAILABLE* ]]
assert_eq 0 "$?" 'public client sees mocked Claude session as AVAILABLE'

response=$(create_target_via_ipc "$old_uuid")
assert_eq $'OK\tok' "$response" 'CREATE request crosses real FIFO/service process boundary'
list=$(run_keepalive list)
[[ $list == *Avela* && $list == *ACTIVE* ]]
assert_eq 0 "$?" 'created target becomes ACTIVE in another client process'

# Exercise actual mocked qdbus sendText from daemon and verify message + carriage-return writes.
run_keepalive refresh >/dev/null
helper_toggle="$TEST_TMP/action-helper.sh"
cat >"$helper_toggle" <<'HELPER'
#!/usr/bin/env bash
set -Eeuo pipefail
ROOT=$1; CMD=$2; UUID=$3
source "$ROOT/lib/common.sh"; source "$ROOT/lib/xdg.sh"; source "$ROOT/lib/ipc.sh"
ka_xdg_init; ka_ensure_runtime_dirs
ka_ipc_call "$CMD" "$UUID"
HELPER
chmod +x "$helper_toggle"
response=$(run_test_user env "${ENV_ARGS[@]}" bash "$helper_toggle" "$TEST_ROOT" SEND_MAIN "$old_uuid")
assert_eq $'OK\tok' "$response" 'manual main send executes through daemon IPC'
assert_contains "$send_log" 'ping' 'daemon sends configured message through mocked Konsole sendText'

# A transport error must cross the real daemon/IPC boundary as ERROR, while the
# failed event remains recorded in the selected target's independent log.
touch "$send_fail_file"
response=$(run_test_user env "${ENV_ARGS[@]}" bash "$helper_toggle" "$TEST_ROOT" SEND_MAIN "$old_uuid")
assert_eq $'ERROR\tmain send failed' "$response" 'manual transport failure propagates through daemon IPC'
assert_contains "$XDG_RUNTIME_DIR/keepalive/logs/$old_uuid.log" $'MAIN\tping\tFAILED · manual' 'daemon logs failed manual transport explicitly'
rm -f -- "$send_fail_file"

# Kill original AI: service must retain target as sticky UNAVAILABLE.
kill "$KA_FAKE_AI_PID" 2>/dev/null || true
sleep 2
list=$(run_keepalive list)
[[ $list == *Avela* && $list == *UNAVAILABLE* ]]
assert_eq 0 "$?" 'lost original AI process becomes sticky UNAVAILABLE'

# New process in same directory gets a different UUID and must remain a separate AVAILABLE row.
printf '%s\n' "$new_uuid" >"$uuid_file"
start_fake_ai
sleep 2
list=$(run_keepalive list)
old_count=$(grep -c 'Avela' <<<"$list" || true)
assert_eq 2 "$old_count" 'old unavailable and replacement available Avela rows coexist'
[[ $list == *UNAVAILABLE* && $list == *AVAILABLE* ]]
assert_eq 0 "$?" 'replacement UUID is never auto-reattached to old keep-alive'

cleanup_integration
trap - EXIT
test_finish
