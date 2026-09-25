#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup

if ! command -v jq >/dev/null 2>&1; then
    printf 'ok 1 - Orca service integration skipped: jq is not installed\n'
    TEST_COUNT=1
    test_finish
    exit
fi

service_log="$TEST_TMP/orca-service.log"
send_log="$TEST_TMP/orca-send.log"
offline_file="$TEST_TMP/orca-offline"
incarnation_file="$TEST_TMP/orca-incarnation"
uuid='orca-runtime-1111-incarnation-2222'

# Role: Run one command as the normal test account, dropping root to nobody in root-based CI.
run_test_user() {
    if ((EUID == 0)); then
        runuser -u nobody -- "$@"
    else
        "$@"
    fi
}

# Role: Build the isolated Orca-only daemon environment as NUL-delimited assignments.
orca_service_env() {
    printf '%s\0' \
        "HOME=$HOME" "XDG_CONFIG_HOME=$XDG_CONFIG_HOME" "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" \
        "XDG_STATE_HOME=$XDG_STATE_HOME" "KEEPALIVE_KONSOLE_ENABLED=0" \
        "KEEPALIVE_ORCA_ENABLED=1" "KEEPALIVE_ORCA_CLI=$TEST_ROOT/tests/fixtures/orca-mock" \
        "KEEPALIVE_JQ=$(command -v jq)" "FAKE_ORCA_SEND_LOG=$send_log" \
        "FAKE_ORCA_ERROR_FILE=$offline_file" "FAKE_ORCA_INCARNATION_FILE=$incarnation_file" \
        "KEEPALIVE_DISCOVERY_INTERVAL=1" "KEEPALIVE_HEALTH_INTERVAL=60" "PATH=/usr/bin:/bin"
}

# Role: Execute the public keepalive client in the same isolated environment as the daemon.
run_keepalive() {
    local -a envs=()
    local item
    while IFS= read -r -d '' item; do envs+=("$item"); done < <(orca_service_env)
    run_test_user env "${envs[@]}" "$TEST_ROOT/keepalive" "$@"
}

# Role: Stop the isolated Orca service process created by this integration test.
cleanup_orca_service() {
    local pid=''
    if [[ -r $XDG_RUNTIME_DIR/keepalive/service.state ]]; then
        pid=$(awk -F '\t' '$1=="pid"{print $2; exit}' "$XDG_RUNTIME_DIR/keepalive/service.state" || true)
        [[ $pid =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    fi
    [[ ${service_wrapper:-} =~ ^[0-9]+$ ]] && kill "$service_wrapper" 2>/dev/null || true
}
trap cleanup_orca_service EXIT

if ((EUID == 0)); then
    chown -R nobody:nogroup "$TEST_TMP"
    chmod 755 "$TEST_TMP"
fi

mapfile -d '' -t ENV_ARGS < <(orca_service_env)
run_test_user env "${ENV_ARGS[@]}" "$TEST_ROOT/keepalive" --service >"$service_log" 2>&1 &
service_wrapper=$!
for _ in {1..80}; do
    [[ -p $XDG_RUNTIME_DIR/keepalive/control.fifo ]] && break
    sleep 0.05
done
assert_true 'Orca-only daemon starts without a Konsole/qdbus backend' \
    test -p "$XDG_RUNTIME_DIR/keepalive/control.fifo"

json=$(run_keepalive list --json)
assert_true 'public discovery exposes the mocked Orca agent' grep -Fq "$uuid" <<<"$json"
assert_true 'machine-readable discovery identifies the Orca backend' \
    grep -Fq '"backend":"orca"' <<<"$json"

assert_eq ok "$(run_keepalive create "$uuid")" 'public CLI creates an Orca keep-alive'
assert_eq ok "$(run_keepalive send "$uuid")" 'manual delivery crosses daemon IPC into Orca'
assert_contains "$send_log" $'handle=term_mock-agent\ttext_set=1\tenter=1\ttext=ping' \
    'daemon uses one atomic Orca text-plus-Enter request'

touch "$offline_file"
offline_response=$(run_keepalive send "$uuid" 2>&1 || true)
assert_eq 'Orca terminal could not be reached or is not writable' "$offline_response" \
    'a transient Orca outage reaches the client with its backend-specific reason'
rm -f -- "$offline_file"
json=$(run_keepalive list --json)
assert_true 'a transient Orca outage does not make identity sticky unavailable' \
    grep -Fq '"status":"ACTIVE"' <<<"$json"

printf '%s\n' replacement-incarnation >"$incarnation_file"
identity_response=$(run_keepalive send "$uuid" 2>&1 || true)
assert_eq 'Orca terminal process incarnation changed' "$identity_response" \
    'pre-send validation rejects a replaced Orca terminal incarnation'
json=$(run_keepalive list --json)
assert_true 'definitive Orca identity loss becomes sticky unavailable' \
    grep -Fq '"status":"UNAVAILABLE"' <<<"$json"

cleanup_orca_service
trap - EXIT
test_finish
