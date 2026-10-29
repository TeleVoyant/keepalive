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
call_log="$TEST_TMP/orca-calls.log"
offline_file="$TEST_TMP/orca-offline"
incarnation_file="$TEST_TMP/orca-incarnation"
schema_file="$TEST_TMP/orca-schema"
orca_wrapper="$TEST_TMP/orca-wrapper"
uuid='orca-runtime-1111-incarnation-2222'
second_uuid='orca-runtime-1111-incarnation-3333'

cat >"$orca_wrapper" <<'WRAPPER'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ ${1-} == terminal && ${2-} == list ]]; then
    printf '%s\t%s\n' "${EPOCHREALTIME:-0}" "$*" >>"$FAKE_ORCA_CALL_LOG"
    if [[ -e ${FAKE_ORCA_SCHEMA_FILE:-} ]]; then
        printf '%s\n' '{"id":"mock-list","ok":true,"result":{"terminals":"changed"},"_meta":{"runtimeId":"runtime-1111"}}'
    else
        printf '%s\n' '{"id":"mock-list","ok":true,"result":{"terminals":[{"handle":"term_mock-agent","ptyId":"repo::/work/Orca-Project@@pty-1","incarnationId":"incarnation-2222","worktreeId":"repo::/work/Orca-Project","worktreePath":"/work/Orca-Project","tabId":"tab-3333","leafId":"leaf-4444","title":"Codex - Orca Project","connected":true,"writable":true,"orphaned":false,"executionHostId":"local","agentIdentity":"codex"},{"handle":"term_second-agent","ptyId":"repo::/work/Orca-Project@@pty-2","incarnationId":"incarnation-3333","worktreeId":"repo::/work/Orca-Project","worktreePath":"/work/Orca-Project","tabId":"tab-5555","leafId":"leaf-6666","title":"Claude - Orca Project","connected":true,"writable":true,"orphaned":false,"executionHostId":"local","agentIdentity":"claude"},{"handle":"term-ptyless","ptyId":null,"incarnationId":null,"worktreeId":"repo::/work/Orca-Project","worktreePath":"/work/Orca-Project","tabId":"tab-7777","leafId":null,"title":"Starting agent","connected":true,"writable":true,"orphaned":false,"executionHostId":"local","agentIdentity":"codex"}],"totalCount":3,"truncated":false},"_meta":{"runtimeId":"runtime-1111"}}'
    fi
    exit 0
fi

exec "$FAKE_ORCA_FIXTURE" "$@"
WRAPPER
chmod 700 "$orca_wrapper"
: >"$call_log"

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
        "KEEPALIVE_ORCA_ENABLED=1" "KEEPALIVE_ORCA_CLI=$orca_wrapper" \
        "FAKE_ORCA_FIXTURE=$TEST_ROOT/tests/fixtures/orca-mock" "FAKE_ORCA_CALL_LOG=$call_log" \
        "FAKE_ORCA_SCHEMA_FILE=$schema_file" \
        "KEEPALIVE_JQ=$(command -v jq)" "FAKE_ORCA_SEND_LOG=$send_log" \
        "FAKE_ORCA_ERROR_FILE=$offline_file" "FAKE_ORCA_INCARNATION_FILE=$incarnation_file" \
        "KEEPALIVE_DISCOVERY_INTERVAL=1" "KEEPALIVE_IDLE_DISCOVERY_INTERVAL=1" \
        "KEEPALIVE_ORCA_DISCOVERY_INTERVAL=2" "KEEPALIVE_ORCA_LIVE_HEALTH_INTERVAL=2" \
        "KEEPALIVE_HEALTH_INTERVAL=60" "KEEPALIVE_STATUS_INTERVAL=1" "PATH=/usr/bin:/bin"
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
    if [[ ${service_wrapper:-} =~ ^[0-9]+$ ]]; then
        kill "$service_wrapper" 2>/dev/null || true
        wait "$service_wrapper" 2>/dev/null || true
    fi
}
trap cleanup_orca_service EXIT

# Role: Count list commands launched by the Orca wrapper, excluding show/send calls.
list_call_count() {
    awk -F '\t' '$2 ~ /^terminal[[:space:]]+list([[:space:]]|$)/ { count += 1 } END { print count + 0 }' "$call_log"
}

# Role: Wait until the wrapper records the requested number of periodic list calls.
wait_for_list_calls() {
    local minimum=$1 count
    for _ in {1..400}; do
        count=$(list_call_count)
        ((count >= minimum)) && return 0
        sleep 0.05
    done
    return 1
}

# Role: Wait for one operator-visible service-log line without racing fixed sleeps.
wait_for_service_line() {
    local needle=$1
    for _ in {1..400}; do
        grep -Fq -- "$needle" "$service_log" 2>/dev/null && return 0
        sleep 0.05
    done
    return 1
}

# Role: Return the smallest millisecond gap between recorded list starts.
minimum_list_gap_ms() {
    awk -F '\t' '
        function millis(value, parts, fraction) {
            split(value, parts, ".")
            fraction=substr((parts[2] "000"), 1, 3)
            return (parts[1] * 1000) + fraction
        }
        $2 ~ /^terminal[[:space:]]+list([[:space:]]|$)/ {
            current=millis($1)
            if (seen && current - previous < minimum) minimum=current - previous
            previous=current
            seen=1
        }
        END { print seen && minimum ? minimum : 0 }
    ' minimum=1500000 "$call_log"
}

if ((EUID == 0)); then
    test_chown_for_unprivileged "$TEST_TMP"
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

assert_true 'startup performs one complete Orca discovery list call' wait_for_list_calls 1

json=$(run_keepalive list --json)
assert_true 'public discovery exposes the mocked Orca agent' grep -Fq "$uuid" <<<"$json"
assert_true 'public discovery exposes a second usable Orca agent' grep -Fq "$second_uuid" <<<"$json"
assert_true 'machine-readable discovery identifies the Orca backend' \
    grep -Fq '"backend":"orca"' <<<"$json"

assert_eq ok "$(run_keepalive create "$uuid")" 'public CLI creates an Orca keep-alive'

# Keep the client-presence stamp fresh so periodic discovery uses the attended cadence. The
# wrapper emits one pty-less agent row; the usable rows must still refresh as a complete pass.
printf '%(%s)T\n' -1 >"$XDG_RUNTIME_DIR/keepalive/clients.seen"
: >"$call_log"
assert_true 'attended Orca discovery reaches three paced periodic passes' wait_for_list_calls 3
assert_true 'attended Orca discovery keeps at least a 1.5 second floor' \
    test "$(minimum_list_gap_ms)" -ge 1500
assert_true 'a pty-less Orca row is reported as skipped rather than a schema failure' \
    wait_for_service_line 'Orca discovery skipped agent rows it cannot bind safely:'
json=$(run_keepalive list --json)
assert_true 'a monitored Orca target remains ACTIVE after skipped-row refreshes' \
    grep -Fq '"status":"ACTIVE"' <<<"$json"
assert_true 'another usable Orca row remains discoverable after skipped-row refreshes' \
    grep -Fq "$second_uuid" <<<"$json"

# A persistent schema error must be one warning per episode, even while periodic attempts
# continue under backoff; recovery is emitted exactly once after the first successful pass.
: >"$schema_file"
: >"$call_log"
assert_true 'schema failure reaches one periodic Orca pass' wait_for_list_calls 1
assert_true 'persistent schema failure reaches three backoff attempts' wait_for_list_calls 3
assert_eq 1 "$(grep -Fc 'Orca discovery did not complete (reason=schema:terminals' "$service_log" || true)" \
    'persistent schema failure logs one warning rather than one warning per pass'
schema_calls=$(list_call_count)
rm -f -- "$schema_file"
assert_true 'recovery waits for the next successful periodic Orca pass' \
    wait_for_list_calls "$((schema_calls + 1))"
assert_true 'successful Orca discovery logs one episode recovery' \
    wait_for_service_line 'Orca discovery recovered after '
assert_eq 1 "$(grep -Fc 'Orca discovery recovered after ' "$service_log" || true)" \
    'persistent Orca schema episode emits exactly one recovery line'

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
