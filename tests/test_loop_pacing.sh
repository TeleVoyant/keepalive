#!/usr/bin/env bash
# Daemon loop pacing, cadence selection, presence parsing, and graceful stop.
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
source "$TEST_ROOT/lib/service.sh"

# Role: Run an isolated command as the unprivileged test account when the suite is root.
run_test_user() {
    if ((EUID == 0)); then
        runuser -u nobody -- "$@"
    else
        "$@"
    fi
}

# Role: Emit the complete isolated environment used by one daemon and its CLI clients.
daemon_env() {
    local root=$1
    local pid_file=$2
    local uuid_file=$3
    local send_log=$4
    printf '%s\0' \
        "HOME=$root/home" "XDG_CONFIG_HOME=$root/config" "XDG_RUNTIME_DIR=$root/runtime" \
        "XDG_STATE_HOME=$root/state" "KEEPALIVE_KONSOLE_ENABLED=1" "KEEPALIVE_ORCA_ENABLED=0" \
        "KEEPALIVE_QDBUS=$TEST_ROOT/tests/fixtures/qdbus-mock" "FAKE_PID_FILE=$pid_file" \
        "FAKE_UUID_FILE=$uuid_file" "FAKE_SEND_LOG=$send_log" "KEEPALIVE_QDBUS_TIMEOUT=1" \
        "KEEPALIVE_DISCOVERY_INTERVAL=1" "KEEPALIVE_IDLE_DISCOVERY_INTERVAL=30" \
        "KEEPALIVE_HEALTH_INTERVAL=1" "KEEPALIVE_STATUS_INTERVAL=15" \
        "KEEPALIVE_RESPONSE_TIMEOUT_MS=8000" "KEEPALIVE_SEND_GAP=0.60" "PATH=/usr/bin:/bin"
}

# Role: Execute the public CLI against one daemon's isolated XDG tree.
run_daemon_cli() {
    local root=$1
    local pid_file=$2
    local uuid_file=$3
    local send_log=$4
    shift 4
    local -a envs=()
    local item
    while IFS= read -r -d '' item; do
        envs+=("$item")
    done < <(daemon_env "$root" "$pid_file" "$uuid_file" "$send_log")
    if ((EUID == 0)); then
        runuser -u nobody -- env "${envs[@]}" "$TEST_ROOT/keepalive" "$@"
    else
        env "${envs[@]}" "$TEST_ROOT/keepalive" "$@"
    fi
}

# Role: Start a non-AI process whose recorded PID makes the qdbus mock discover no target.
start_idle_process() {
    local pid_file=$1
    if ((EUID == 0)); then
        runuser -u nobody -- env PID_FILE="$pid_file" bash -c \
            'printf "%s\\n" "$$" >"$PID_FILE"; exec sleep 30' &
    else
        env PID_FILE="$pid_file" bash -c \
            'printf "%s\\n" "$$" >"$PID_FILE"; exec sleep 30' &
    fi
    IDLE_WRAPPER_PID=$!
    for _ in {1..100}; do
        [[ -s $pid_file ]] && break
        ka_sleep 0.01
    done
    [[ -s $pid_file ]] || return 1
    IDLE_PID=$(<"$pid_file")
    [[ $IDLE_PID =~ ^[0-9]+$ ]]
}

# Role: Start a recognized Claude-shaped process without creating an untracked child.
start_claude_process() {
    local pid_file=$1
    local hold_fifo=$2
    local work_dir=$3
    local script=$4
    if ((EUID == 0)); then
        runuser -u nobody -- env FAKE_AI_PID_FILE="$pid_file" FAKE_HOLD_FIFO="$hold_fifo" \
            bash -c 'cd "$1" && exec "$2"' bash "$work_dir" "$script" &
    else
        env FAKE_AI_PID_FILE="$pid_file" FAKE_HOLD_FIFO="$hold_fifo" \
            bash -c 'cd "$1" && exec "$2"' bash "$work_dir" "$script" &
    fi
    CLAUDE_WRAPPER_PID=$!
    for _ in {1..100}; do
        [[ -s $pid_file ]] && break
        ka_sleep 0.01
    done
    [[ -s $pid_file ]] || return 1
    CLAUDE_PID=$(<"$pid_file")
    [[ $CLAUDE_PID =~ ^[0-9]+$ ]]
}

# Role: Start a real isolated daemon and record both its launcher and service PID.
start_daemon() {
    local root=$1
    local pid_file=$2
    local uuid_file=$3
    local send_log=$4
    local log_file="$root/service.log"
    local -a envs=()
    local item
    while IFS= read -r -d '' item; do
        envs+=("$item")
    done < <(daemon_env "$root" "$pid_file" "$uuid_file" "$send_log")
    if ((EUID == 0)); then
        runuser -u nobody -- env "${envs[@]}" "$TEST_ROOT/keepalive" --service >"$log_file" 2>&1 &
    else
        env "${envs[@]}" "$TEST_ROOT/keepalive" --service >"$log_file" 2>&1 &
    fi
    DAEMON_WRAPPER_PID=$!
    for _ in {1..160}; do
        [[ -p $root/runtime/keepalive/control.fifo ]] && break
        ka_sleep 0.025
    done
    [[ -p $root/runtime/keepalive/control.fifo ]] || return 1
    for _ in {1..80}; do
        [[ -r $root/runtime/keepalive/service.state ]] && break
        ka_sleep 0.025
    done
    [[ -r $root/runtime/keepalive/service.state ]] || return 1
    DAEMON_PID=$(awk -F '\t' '$1 == "pid" { print $2; exit }' "$root/runtime/keepalive/service.state")
    [[ $DAEMON_PID =~ ^[0-9]+$ ]] || return 1
    [[ -d /proc/$DAEMON_PID ]]
}

# Role: Terminate and reap every process this test starts, using only recorded PIDs.
cleanup_started_processes() {
    local pid
    for pid in "${flight_cli_pid:-}" "${DAEMON_PID:-}" "${DAEMON_WRAPPER_PID:-}" \
        "${CLAUDE_PID:-}" "${CLAUDE_WRAPPER_PID:-}" "${IDLE_PID:-}" "${IDLE_WRAPPER_PID:-}"; do
        [[ $pid =~ ^[0-9]+$ ]] && kill "$pid" 2>/dev/null || true
    done
    for pid in "${flight_cli_pid:-}" "${DAEMON_WRAPPER_PID:-}" "${CLAUDE_WRAPPER_PID:-}" \
        "${IDLE_WRAPPER_PID:-}"; do
        [[ $pid =~ ^[0-9]+$ ]] && wait "$pid" 2>/dev/null || true
    done
}
trap cleanup_started_processes EXIT

# Monotonic millisecond parsing is a hot path: fractions are padded/truncated to ms,
# integer-only uptime is valid, and malformed or unreasonably wide input fails closed.
clock_file="$TEST_TMP/monotonic.ms"
export KEEPALIVE_MONOTONIC_FILE=$clock_file
printf '123.4\n' >"$clock_file"
ka_now_monotonic_ms
assert_eq 123400 "$REPLY" 'monotonic milliseconds pad a one-digit fraction'
printf '123.45\n' >"$clock_file"
ka_now_monotonic_ms
assert_eq 123450 "$REPLY" 'monotonic milliseconds pad a two-digit fraction'
printf '123\n' >"$clock_file"
ka_now_monotonic_ms
assert_eq 123000 "$REPLY" 'monotonic milliseconds accept integer-only uptime'
printf '123.456789\n' >"$clock_file"
ka_now_monotonic_ms
assert_eq 123456 "$REPLY" 'monotonic milliseconds use only millisecond precision'
printf '1234567890123.4\n' >"$clock_file"
assert_false 'monotonic milliseconds reject more than twelve integer digits' ka_now_monotonic_ms
printf '123.garbage\n' >"$clock_file"
assert_false 'monotonic milliseconds reject garbage after the decimal point' ka_now_monotonic_ms
printf 'not-a-clock\n' >"$clock_file"
assert_false 'monotonic milliseconds reject a non-numeric source' ka_now_monotonic_ms
unset KEEPALIVE_MONOTONIC_FILE

# Presence stamps select the expensive cadence only while a recent client is attached.
export KEEPALIVE_DISCOVERY_INTERVAL=2
export KEEPALIVE_IDLE_DISCOVERY_INTERVAL=30
export KEEPALIVE_CLIENT_PRESENCE_TTL=20
export KEEPALIVE_STATUS_INTERVAL=17
presence_now=$(ka_now_epoch)
printf '%s\n' "$presence_now" >"$KA_CLIENT_PRESENCE_FILE"
ka_service_discovery_interval
assert_eq 1 "$KA_CLIENT_PRESENT" 'a fresh bare presence stamp selects attached mode'
assert_eq 2 "$KA_DISCOVERY_INTERVAL" 'attached mode uses the fast discovery interval'
assert_eq 1 "$KA_PUBLISH_INTERVAL" 'attached mode publishes the index every second'
printf '%s\033[K\n' "$presence_now" >"$KA_CLIENT_PRESENCE_FILE"
ka_service_discovery_interval
assert_eq 1 "$KA_CLIENT_PRESENT" 'an old erase-suffixed presence stamp remains compatible'
printf '%s\n' "$((presence_now - 21))" >"$KA_CLIENT_PRESENCE_FILE"
ka_service_discovery_interval
assert_eq 0 "$KA_CLIENT_PRESENT" 'a stale presence stamp selects idle mode'
assert_eq 17 "$KA_PUBLISH_INTERVAL" 'idle mode uses the configured status interval'
printf '1234567890123\n' >"$KA_CLIENT_PRESENCE_FILE"
ka_service_discovery_interval
assert_eq 0 "$KA_CLIENT_PRESENT" 'a thirteen-digit presence stamp is rejected'
printf '9223372036854775807\n' >"$KA_CLIENT_PRESENCE_FILE"
ka_service_discovery_interval
assert_eq 0 "$KA_CLIENT_PRESENT" 'an overflowing presence stamp is rejected'
unset KEEPALIVE_DISCOVERY_INTERVAL KEEPALIVE_IDLE_DISCOVERY_INTERVAL KEEPALIVE_CLIENT_PRESENCE_TTL KEEPALIVE_STATUS_INTERVAL

# Scan status and backend snapshot ages independently determine wake planning.
ka_state_init_arrays
active_uuid='active-konsole-1111'
paused_uuid='paused-orca-2222'
unavailable_uuid='lost-konsole-3333'
KA_T_UUIDS=("$active_uuid" "$paused_uuid" "$unavailable_uuid")
KA_T_STATUS[$active_uuid]=ACTIVE
KA_T_STATUS[$paused_uuid]=PAUSED
KA_T_STATUS[$unavailable_uuid]=UNAVAILABLE
KA_T_BACKEND[$active_uuid]=konsole
KA_T_BACKEND[$paused_uuid]=orca
KA_T_BACKEND[$unavailable_uuid]=konsole
KA_KONSOLE_ENABLED=1
KA_ORCA_ENABLED=1
unset KEEPALIVE_IDLE_DISCOVERY_INTERVAL KEEPALIVE_SNAPSHOT_MAX_AGE KEEPALIVE_ORCA_SNAPSHOT_MAX_AGE
ka_service_scan_targets
assert_eq 1 "$KA_SVC_ACTIVE" 'a mixed target set is active when one target is ACTIVE'
assert_eq 1 "$KA_SVC_MONITORED" 'a mixed target set is monitored when ACTIVE or PAUSED'
assert_eq orca "${KA_SVC_IDLE_DISCOVERY[*]}" 'idle discovery defaults to Orca only because its snapshot spans idle cadence'
KA_T_UUIDS=("$paused_uuid")
ka_service_scan_targets
assert_eq 0 "$KA_SVC_ACTIVE" 'PAUSED-only targets do not schedule active timer ticks'
assert_eq 1 "$KA_SVC_MONITORED" 'PAUSED-only targets still schedule health monitoring'
KA_T_UUIDS=("$unavailable_uuid")
ka_service_scan_targets
assert_eq 0 "$KA_SVC_ACTIVE" 'UNAVAILABLE-only targets are not active'
assert_eq 0 "$KA_SVC_MONITORED" 'UNAVAILABLE-only targets are not monitored'
KA_T_UUIDS=("$active_uuid" "$paused_uuid")
export KEEPALIVE_SNAPSHOT_MAX_AGE=30
ka_service_scan_targets
assert_eq 'konsole orca' "${KA_SVC_IDLE_DISCOVERY[*]}" 'snapshot max-age override includes Konsole in idle discovery'
KA_KONSOLE_ENABLED=0
ka_service_scan_targets
assert_eq orca "${KA_SVC_IDLE_DISCOVERY[*]}" 'disabled Konsole is excluded from idle discovery'
KA_ORCA_ENABLED=0
ka_service_scan_targets
assert_eq 0 "${#KA_SVC_IDLE_DISCOVERY[@]}" 'disabled backends are all excluded from idle discovery'
unset KEEPALIVE_SNAPSHOT_MAX_AGE

# Orca discovery failures back off exponentially and a success clears the episode.
KA_CLIENT_PRESENT=1
KA_KONSOLE_ENABLED=0
KA_ORCA_ENABLED=1
KA_SVC_IDLE_DISCOVERY=()
KA_ORCA_DISCOVERY_FAILURE=offline
KA_ORCA_FAILURES=0
KA_ORCA_RETRY_AT=0
backoff_now=0
for expected_delay in 2 4 8 16 32 60 60; do
    ka_service_note_orca_discovery "$backoff_now"
    assert_eq "$expected_delay" "$((KA_ORCA_RETRY_AT - backoff_now))" \
        "Orca discovery backoff delay is capped sequence value $expected_delay"
    backoff_now=$KA_ORCA_RETRY_AT
done
ka_service_discovery_backends "$((backoff_now - 1))"
assert_eq 0 "${#KA_SVC_DISCOVER[@]}" 'Orca discovery is skipped while its backoff is active'
ka_service_discovery_backends "$backoff_now"
assert_eq orca "${KA_SVC_DISCOVER[*]}" 'Orca discovery resumes when its backoff expires'
KA_ORCA_FAILURES=6
KA_ORCA_RETRY_AT=999
KA_ORCA_DISCOVERY_FAILURE=''
ka_service_discovery_backends 100
assert_eq 0 "$KA_ORCA_FAILURES" 'a successful refresh resets Orca failure count'
assert_eq 0 "$KA_ORCA_RETRY_AT" 'a successful refresh clears the Orca retry deadline'
assert_eq orca "${KA_SVC_DISCOVER[*]}" 'a successful refresh permits the next Orca discovery'

# Prepare two independent isolated daemon homes after all direct helper assertions.
idle_root="$TEST_TMP/idle-daemon"
flight_root="$TEST_TMP/flight-daemon"
mkdir -p "$idle_root/home" "$idle_root/config" "$idle_root/runtime" "$idle_root/state" \
    "$flight_root/home" "$flight_root/config" "$flight_root/runtime" "$flight_root/state"
chmod 700 "$idle_root/runtime" "$flight_root/runtime"
idle_pid_file="$idle_root/fake.pid"
idle_uuid_file="$idle_root/fake.uuid"
idle_send_log="$idle_root/send.log"
printf 'idle-session-1111\n' >"$idle_uuid_file"
flight_pid_file="$flight_root/fake.pid"
flight_uuid_file="$flight_root/fake.uuid"
flight_send_log="$flight_root/send.log"
flight_uuid='flight-session-4444'
printf '%s\n' "$flight_uuid" >"$flight_uuid_file"
flight_profile_messages="$flight_root/config/keepalive/profile/messages"
mkdir -p "$flight_profile_messages"
printf 'ping\n' >"$flight_profile_messages/001"
printf 'pong\n' >"$flight_profile_messages/002"
claude_script="$TEST_TMP/claude"
cat >"$claude_script" <<'FAKEAI'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$$" >"$FAKE_AI_PID_FILE"
while :; do
    IFS= read -r _ <"$FAKE_HOLD_FIFO"
done
FAKEAI
chmod 755 "$claude_script"
claude_hold_fifo="$TEST_TMP/claude.hold"
mkfifo "$claude_hold_fifo"
chmod 666 "$claude_hold_fifo"
claude_work="$TEST_TMP/ClaudeProject"
mkdir -p "$claude_work"
: >"$idle_send_log"
: >"$flight_send_log"
if ((EUID == 0)); then
    test_chown_for_unprivileged "$TEST_TMP"
    chmod 755 "$TEST_TMP"
fi

# The idle daemon must sleep rather than polling five times per second, yet still wake for IPC.
start_idle_process "$idle_pid_file"
start_daemon "$idle_root" "$idle_pid_file" "$idle_uuid_file" "$idle_send_log"
idle_daemon_pid=$DAEMON_PID
assert_true 'isolated daemon starts with a qdbus mock and Orca disabled' test -p "$idle_root/runtime/keepalive/control.fifo"
assert_true 'idle daemon has no monitored target rows' test ! -e "$idle_root/runtime/keepalive/targets/idle-session-1111/state.tsv"
voluntary_before=$(awk '/^voluntary_ctxt_switches:/ {print $2}' "/proc/$idle_daemon_pid/status")
ka_sleep 6
voluntary_after=$(awk '/^voluntary_ctxt_switches:/ {print $2}' "/proc/$idle_daemon_pid/status")
voluntary_delta=$((voluntary_after - voluntary_before))
assert_true 'idle daemon performs far fewer than five polling wakes per second' test "$voluntary_delta" -lt 15
ka_sleep 1
ka_now_ms
status_started=$REPLY
status_output=$(run_daemon_cli "$idle_root" "$idle_pid_file" "$idle_uuid_file" "$idle_send_log" status)
ka_now_ms
status_elapsed=$((REPLY - status_started))
assert_eq 'Keep Alive service: online' "$status_output" 'CLI request wakes a daemon in a long idle wait'
assert_true 'CLI request is answered within one second during the long wait' test "$status_elapsed" -lt 1000
ka_now_ms
idle_stop_started=$REPLY
kill -TERM "$idle_daemon_pid"
idle_wait_rc=0
wait "$DAEMON_WRAPPER_PID" || idle_wait_rc=$?
ka_now_ms
idle_stop_elapsed=$((REPLY - idle_stop_started))
assert_eq 143 "$idle_wait_rc" 'TERM while idle exits with signal status 143'
assert_true 'TERM while idle exits within one second' test "$idle_stop_elapsed" -lt 1000
assert_eq stopped "$(awk -F '\t' '$1 == "state" {print $2; exit}' "$idle_root/runtime/keepalive/service.state")" \
    'idle TERM cleanup publishes service.state stopped'
kill "$IDLE_PID" 2>/dev/null || true
idle_reap_rc=0
wait "$IDLE_WRAPPER_PID" || idle_reap_rc=$?
assert_false 'idle fake process is reaped after the daemon measurement' test -d "/proc/$IDLE_PID"

# A paused-only target must not emit scheduler-gap events during an otherwise idle period.
start_claude_process "$flight_pid_file" "$claude_hold_fifo" "$claude_work" "$claude_script"
start_daemon "$flight_root" "$flight_pid_file" "$flight_uuid_file" "$flight_send_log"
flight_json=$(run_daemon_cli "$flight_root" "$flight_pid_file" "$flight_uuid_file" "$flight_send_log" list --json)
assert_true 'flight daemon discovers the recognized mocked Claude session' grep -Fq "$flight_uuid" <<<"$flight_json"
assert_eq ok "$(run_daemon_cli "$flight_root" "$flight_pid_file" "$flight_uuid_file" "$flight_send_log" create "$flight_uuid")" \
    'public CLI creates the delivery target through the real daemon'
flight_state="$flight_root/runtime/keepalive/targets/$flight_uuid/state.tsv"
assert_eq ok "$(run_daemon_cli "$flight_root" "$flight_pid_file" "$flight_uuid_file" "$flight_send_log" pause "$flight_uuid")" \
    'public CLI pauses the target'
ka_sleep 3
assert_eq PAUSED "$(awk -F '\t' '$1 == "status" {print $2; exit}' "$flight_state")" \
    'the target remains PAUSED throughout its idle period'
assert_false 'a PAUSED-only idle period emits no scheduler gap event' \
    grep -aFq 'scheduler gap' "$flight_root/runtime/keepalive/logs/$flight_uuid.log"
assert_eq ok "$(run_daemon_cli "$flight_root" "$flight_pid_file" "$flight_uuid_file" "$flight_send_log" resume "$flight_uuid")" \
    'public CLI resumes the target before an in-flight delivery'

# TERM during the two-call Konsole delivery must let both text and Enter complete first.
: >"$flight_send_log"
flight_response="$flight_root/send-response"
run_daemon_cli "$flight_root" "$flight_pid_file" "$flight_uuid_file" "$flight_send_log" send "$flight_uuid" >"$flight_response" 2>&1 &
flight_cli_pid=$!
for _ in {1..100}; do
    grep -aFq 'ping' "$flight_send_log" && break
    ka_sleep 0.02
done
assert_true 'in-flight delivery records its text before TERM' grep -aFq 'ping' "$flight_send_log"
ka_now_ms
flight_stop_started=$REPLY
kill -TERM "$DAEMON_PID"
flight_wait_rc=0
wait "$flight_cli_pid" || flight_wait_rc=$?
flight_cli_pid=''
flight_response_text=$(<"$flight_response")
assert_eq ok "$flight_response_text" 'in-flight CLI request receives success after TERM'
flight_wrapper_wait_rc=0
wait "$DAEMON_WRAPPER_PID" || flight_wrapper_wait_rc=$?
ka_now_ms
flight_stop_elapsed=$((REPLY - flight_stop_started))
assert_eq 143 "$flight_wrapper_wait_rc" 'TERM after delivery started exits with signal status 143'
assert_true 'in-flight TERM exits promptly after the delivery gap' test "$flight_stop_elapsed" -lt 1000
assert_true 'completed delivery records the Enter separately from its text' grep -aFq $'\r' "$flight_send_log"
assert_eq 1 "$(awk -F '\t' '$1 == "main_index" {print $2; exit}' "$flight_state")" \
    'completed in-flight delivery advances the persisted target checkpoint'
assert_eq stopped "$(awk -F '\t' '$1 == "state" {print $2; exit}' "$flight_root/runtime/keepalive/service.state")" \
    'in-flight TERM cleanup publishes service.state stopped'
kill "$CLAUDE_PID" 2>/dev/null || true
claude_reap_rc=0
wait "$CLAUDE_WRAPPER_PID" || claude_reap_rc=$?
assert_false 'mock Claude process is reaped after graceful stop' test -d "/proc/$CLAUDE_PID"

cleanup_started_processes
trap - EXIT
test_finish
