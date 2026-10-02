#!/usr/bin/env bash
# Profile/request scalar safety, event-log hardening, IPC publication, and stale retries.
set -Eeuo pipefail

# Root CI must exercise ownership-sensitive read-only behavior as a real unprivileged user.
if ((EUID == 0)) && [[ ${KEEPALIVE_IO_TEST_UNPRIV:-0} != 1 ]]; then
    script_path=$0
    [[ $script_path == /* ]] || script_path="$PWD/$script_path"
    exec runuser -u nobody -- env KEEPALIVE_IO_TEST_UNPRIV=1 /bin/bash "$script_path" "$@"
fi

source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
source "$TEST_ROOT/lib/service.sh"

# Role: Run a bounded scalar read in a child so a planted FIFO can never wedge this test.
run_scalar_fifo_probe() {
    local path=$1 probe="$TEST_TMP/scalar-fifo-probe.sh"
    cat >"$probe" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$PROBE_ROOT/tests/testlib.sh"
test_env_setup
trap 'rm -rf -- "$TEST_TMP"' EXIT
source_core
ka_request_read_scalar "$PROBE_PATH" 8
PROBE
    chmod 700 "$probe"
    env PROBE_ROOT="$TEST_ROOT" PROBE_PATH="$path" timeout 1 /bin/bash "$probe"
}

# Role: Run an isolated event-log append against a FIFO and capture its one warning.
run_log_fifo_probe() {
    local log_dir=$1 error_file=$2 probe="$TEST_TMP/log-fifo-probe.sh"
    cat >"$probe" <<'PROBE'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$PROBE_ROOT/tests/testlib.sh"
test_env_setup
trap 'rm -rf -- "$TEST_TMP"' EXIT
source_core
KA_LOGS_DIR=$PROBE_LOG_DIR
KA_LOG_WARNED=()
KA_LOG_WRITES=()
ka_log_event fifo SERVICE first ok 2>"$PROBE_ERROR"
ka_log_event fifo SERVICE second ok 2>>"$PROBE_ERROR"
PROBE
    chmod 700 "$probe"
    env PROBE_ROOT="$TEST_ROOT" PROBE_LOG_DIR="$log_dir" PROBE_ERROR="$error_file" \
        timeout 1 /bin/bash "$probe"
}

# Role: Record one deterministic IPC request directory for a publication-failure probe.
make_send_request() {
    local id=$1 command=$2 dir
    dir=$(ka_ipc_request_dir "$id")
    mkdir -- "$dir"
    ka_write_scalar "$dir/command" "$command"
    ka_write_scalar "$dir/uuid" send-target
}

# Role: Return deterministic monotonic milliseconds for the in-process service-loop fake.
ka_io_fake_monotonic_ms() {
    REPLY=$FAKE_LOOP_MS
}

# Role: Return deterministic monotonic seconds for the in-process service-loop fake.
ka_io_fake_monotonic() {
    FAKE_NOW_S=$((FAKE_LOOP_MS / 1000))
    REPLY=$FAKE_NOW_S
}

# Role: Advance the fake service clock by 100 ms and report an idle FIFO timeout.
ka_io_fake_service_read() {
    FAKE_LOOP_MS=$((FAKE_LOOP_MS + 100))
    return 1
}

# Role: Keep the fake service loop in attended one-second publication mode.
ka_io_fake_discovery_interval() {
    KA_CLIENT_PRESENT=1
    KA_DISCOVERY_INTERVAL=100
    KA_PUBLISH_INTERVAL=1
}

# Role: Give the fake service loop no monitored targets or backend discovery work.
ka_io_fake_scan_targets() {
    KA_SVC_ACTIVE=0
    KA_SVC_MONITORED=0
    KA_SVC_IDLE_DISCOVERY=()
}

# Role: End the fake service loop immediately after the recovery publication at 3 seconds.
ka_io_fake_runtime_present() {
    ((FAKE_LOOP_MS <= 3000))
}

# Role: Fail the first two fake index publications and recover on the third attempt.
ka_io_fake_publish_index() {
    FAKE_PUBLISH_SECONDS+=("$FAKE_NOW_S")
    ((FAKE_PUBLISH_COUNT += 1))
    if ((FAKE_PUBLISH_COUNT <= 2)); then
        return 79
    fi
    return 0
}

# --- Profile snapshots and scalar readers ---------------------------------------------
ka_profile_init_defaults
chmod 400 \
    "$KA_PROFILE_DIR/main_interval" "$KA_PROFILE_DIR/secondary_enabled" \
    "$KA_PROFILE_DIR/secondary_interval" "$KA_PROFILE_DIR/secondary_message" \
    "$KA_PROFILE_DIR/notifications" "$KA_PROFILE_DIR/delivery_mode" \
    "$KA_PROFILE_DIR/messages/001" "$KA_CONFIG_DIR/profile.lock"
chmod 500 "$KA_PROFILE_DIR" "$KA_PROFILE_DIR/messages"

readonly_request="$TEST_TMP/readonly-request"
readonly_copy_rc=0
ka_profile_copy_to_request "$readonly_request" || readonly_copy_rc=$?
assert_eq 0 "$readonly_copy_rc" 'profile snapshot copies mode-0400 scalars and messages'
assert_eq 1500 "$(ka_read_first_line "$readonly_request/main_interval")" \
    'read-only profile scalar is copied intact'
assert_eq ping "$(ka_read_first_line "$readonly_request/messages/001")" \
    'read-only profile message is copied intact'

chmod 400 "$KA_CONFIG_DIR/profile.lock"
readonly_print="$TEST_TMP/profile-print.txt"
readonly_print_rc=0
ka_profile_print >"$readonly_print" || readonly_print_rc=$?
assert_eq 0 "$readonly_print_rc" 'profile print opens an existing mode-0400 lock read-only'
assert_contains "$readonly_print" 'main_interval=1500' \
    'profile print reads mode-0400 profile scalars'
assert_contains "$readonly_print" '  - ping' \
    'profile print reads mode-0400 message files'

# --- Profile destination path hardening ------------------------------------------------
external_profile="$TEST_TMP/external-profile"
mkdir -- "$external_profile"
printf 'sentinel' >"$external_profile/sentinel"
profile_link="$TEST_TMP/profile-link"
ln -s -- "$external_profile" "$profile_link"
link_copy_rc=0
ka_profile_copy_to_request "$profile_link" 2>"$TEST_TMP/profile-link.err" || link_copy_rc=$?
assert_true 'symlinked profile request destination is refused' test "$link_copy_rc" -ne 0
assert_eq sentinel "$(<"$external_profile/sentinel")" \
    'symlinked profile request destination leaves external data unchanged'
assert_false 'symlinked profile request destination creates no external messages' \
    test -e "$external_profile/messages"

new_profile_request="$TEST_TMP/new-profile-request"
new_copy_rc=0
ka_profile_copy_to_request "$new_profile_request" || new_copy_rc=$?
assert_eq 0 "$new_copy_rc" 'profile copy creates a not-yet-existing final request level'
assert_true 'new profile request contains its messages directory' \
    test -d "$new_profile_request/messages"

ancestor_external="$TEST_TMP/ancestor-external"
mkdir -- "$ancestor_external"
printf 'sentinel' >"$ancestor_external/sentinel"
ln -s -- "$ancestor_external" "$TEST_TMP/profile-ancestor"
ancestor_request="$TEST_TMP/profile-ancestor/request"
ancestor_copy_rc=0
ka_profile_copy_to_request "$ancestor_request" 2>"$TEST_TMP/profile-ancestor.err" || ancestor_copy_rc=$?
assert_true 'symlinked profile request ancestor is refused' test "$ancestor_copy_rc" -ne 0
assert_false 'symlinked profile ancestor receives no copied scalar' \
    test -e "$ancestor_external/request/main_interval"
assert_false 'symlinked profile ancestor receives no messages directory' \
    test -e "$ancestor_external/request/messages"
assert_false 'symlinked profile ancestor does not even receive the request directory' \
    test -e "$ancestor_external/request"

# --- Bounded scalar reads ----------------------------------------------------------------
scalar_file="$TEST_TMP/scalar"
printf '' >"$scalar_file"
scalar_rc=0
ka_request_read_scalar "$scalar_file" 8 || scalar_rc=$?
assert_eq 0 "$scalar_rc" 'empty scalar is accepted'
assert_eq '' "$REPLY" 'empty scalar returns an empty value'

printf 'trailing\n' >"$scalar_file"
scalar_rc=0
ka_request_read_scalar "$scalar_file" 8 || scalar_rc=$?
assert_eq 0 "$scalar_rc" 'one trailing newline is accepted'
assert_eq trailing "$REPLY" 'trailing newline is removed from the scalar value'

printf '%s' no-newline >"$scalar_file"
scalar_rc=0
ka_request_read_scalar "$scalar_file" 16 || scalar_rc=$?
assert_eq 0 "$scalar_rc" 'a scalar without a final newline is accepted'
assert_eq no-newline "$REPLY" 'a scalar without a final newline preserves its value'

printf '1234' >"$scalar_file"
scalar_rc=0
ka_request_read_scalar "$scalar_file" 4 || scalar_rc=$?
assert_eq 0 "$scalar_rc" 'an ASCII scalar at the exact maximum is accepted'
assert_eq 1234 "$REPLY" 'an exact-maximum ASCII scalar is returned intact'

printf 'éé' >"$scalar_file"
scalar_rc=0
ka_request_read_scalar "$scalar_file" 4 || scalar_rc=$?
assert_eq 0 "$scalar_rc" 'multibyte text whose UTF-8 bytes meet the maximum is accepted'
assert_eq éé "$REPLY" 'multibyte text at the maximum is returned intact'

printf '12345' >"$scalar_file"
scalar_rc=0
ka_request_read_scalar "$scalar_file" 4 || scalar_rc=$?
assert_true 'an oversized scalar is refused' test "$scalar_rc" -ne 0

printf 'one\ntwo' >"$scalar_file"
scalar_rc=0
ka_request_read_scalar "$scalar_file" 8 || scalar_rc=$?
assert_true 'a multi-line scalar is refused' test "$scalar_rc" -ne 0

scalar_external="$TEST_TMP/scalar-external"
printf external >"$scalar_external"
ln -sf -- "$scalar_external" "$TEST_TMP/scalar-link"
scalar_rc=0
ka_request_read_scalar "$TEST_TMP/scalar-link" 32 || scalar_rc=$?
assert_true 'a symlinked scalar is refused' test "$scalar_rc" -ne 0
assert_eq external "$(<"$scalar_external")" 'a refused scalar symlink is never followed'

mkfifo "$TEST_TMP/scalar-fifo"
fifo_scalar_rc=0
run_scalar_fifo_probe "$TEST_TMP/scalar-fifo" || fifo_scalar_rc=$?
assert_true 'a planted scalar FIFO returns failure rather than timing out' \
    test "$fifo_scalar_rc" -ne 124
assert_true 'a planted scalar FIFO is rejected' test "$fifo_scalar_rc" -ne 0

# --- Tunable bounds --------------------------------------------------------------------
TUNABLE_NINE_DIGIT=999999999
ka_tunable TUNABLE_NINE_DIGIT 7 2>"$TEST_TMP/tunable-nine.err"
assert_eq 999999999 "$REPLY" 'a nine-digit tunable is accepted'
assert_true 'an accepted nine-digit tunable emits no warning' \
    test ! -s "$TEST_TMP/tunable-nine.err"

TUNABLE_TEN_DIGIT=1000000000
ka_tunable TUNABLE_TEN_DIGIT 7 2>"$TEST_TMP/tunable-ten.err"
assert_eq 7 "$REPLY" 'a ten-digit tunable falls back to its default'
assert_contains "$TEST_TMP/tunable-ten.err" 'at most 9 digits' \
    'a ten-digit tunable explains its bounded fallback'

TUNABLE_LEADING_ZERO=000000001
ka_tunable TUNABLE_LEADING_ZERO 7 2>"$TEST_TMP/tunable-leading.err"
assert_eq 7 "$REPLY" 'a leading-zero tunable falls back to its default'
assert_contains "$TEST_TMP/tunable-leading.err" 'at most 9 digits' \
    'a leading-zero tunable explains its bounded fallback'

# --- Event-log path and trim hardening -------------------------------------------------
KA_LOG_WARNED=()
KA_LOG_WRITES=()
log_external="$TEST_TMP/log-external"
mkdir -- "$log_external"
printf sentinel >"$log_external/victim"
ln -s -- "$log_external/victim" "$KA_LOGS_DIR/symlink.log"
symlink_log_rc=0
ka_log_event symlink SERVICE first ok 2>"$TEST_TMP/symlink-log.err" || symlink_log_rc=$?
ka_log_event symlink SERVICE second ok 2>>"$TEST_TMP/symlink-log.err" || symlink_log_rc=$?
assert_eq 0 "$symlink_log_rc" 'symlinked event logs are skipped without failing delivery'
assert_eq sentinel "$(<"$log_external/victim")" 'symlinked event logs never write externally'
symlink_warns=$(grep -Fc 'skipping unsafe event log' "$TEST_TMP/symlink-log.err" || true)
assert_eq 1 "$symlink_warns" 'a symlinked event log emits only one warning'

fifo_log="$KA_LOGS_DIR/fifo.log"
mkfifo "$fifo_log"
fifo_log_rc=0
run_log_fifo_probe "$KA_LOGS_DIR" "$TEST_TMP/fifo-log.err" || fifo_log_rc=$?
assert_true 'a planted FIFO event log returns rather than blocking' test "$fifo_log_rc" -ne 124
assert_eq 0 "$fifo_log_rc" 'a planted FIFO event log is skipped successfully'
fifo_warns=$(grep -Fc 'skipping unsafe event log' "$TEST_TMP/fifo-log.err" || true)
assert_eq 1 "$fifo_warns" 'a FIFO event log emits only one warning'
assert_true 'a planted FIFO event log remains untouched' test -p "$fifo_log"

trim_log="$KA_LOGS_DIR/trim.log"
printf 'line-1\nline-2\nline-3\nline-4\n' >"$trim_log"
chmod 600 "$trim_log"
trim_victim="$TEST_TMP/trim-victim"
printf sentinel >"$trim_victim"
fake_bin="$TEST_TMP/fake-tail-bin"
mkdir -- "$fake_bin"
real_tail=$(type -P tail)
cat >"$fake_bin/tail" <<'TAIL'
#!/usr/bin/env bash
set -Eeuo pipefail
mv -- "$TRIM_PATH" "$TRIM_SAVED"
ln -s -- "$TRIM_VICTIM" "$TRIM_PATH"
exec "$REAL_TAIL" "$@"
TAIL
chmod 700 "$fake_bin/tail"
export TRIM_PATH="$trim_log" TRIM_SAVED="$trim_log.saved" TRIM_VICTIM="$trim_victim" REAL_TAIL="$real_tail"
old_path=$PATH
export PATH="$fake_bin:$PATH"
trim_swap_rc=0
KEEPALIVE_LOG_MAX_LINES=2 ka_log_trim "$trim_log" || trim_swap_rc=$?
export PATH=$old_path
assert_eq 0 "$trim_swap_rc" 'log trim tolerates a path swap after opening its descriptor'
assert_true 'log trim keeps the held source path as a refused symlink' test -L "$trim_log"
assert_eq sentinel "$(<"$trim_victim")" 'log trim never writes through a swapped log symlink'
trim_temp_paths=$(find "$KA_LOGS_DIR" -maxdepth 1 -type f -name '.*.tmp.*' -print 2>/dev/null)
assert_eq '' "$trim_temp_paths" 'descriptor-held log trim leaves no temporary files after a swap'
rm -f -- "$trim_log"
mv -- "$trim_log.saved" "$trim_log"

KEEPALIVE_LOG_MAX_LINES=2
ka_log_trim "$trim_log"
trim_content=$(<"$trim_log")
assert_eq $'line-3\nline-4' "$trim_content" 'log trim retains the newest N lines'
trim_temp_paths=$(find "$KA_LOGS_DIR" -maxdepth 1 -type f -name '.*.tmp.*' -print 2>/dev/null)
assert_eq '' "$trim_temp_paths" 'successful log trim leaves no temporary files'

# --- IPC command success after deferred index publication --------------------------------
ka_state_init_arrays
KA_INDEX_STALE=0
SEND_MAIN_CALLS=0
SEND_SECONDARY_CALLS=0

# Role: Stub successful main delivery while recording that the IPC path dispatched it.
ka_scheduler_send_main() {
    ((SEND_MAIN_CALLS += 1))
    return 0
}

# Role: Stub successful secondary delivery while recording that the IPC path dispatched it.
ka_scheduler_send_secondary() {
    ((SEND_SECONDARY_CALLS += 1))
    return 0
}

# Role: Force every IPC index publication to fail after a command has completed.
ka_state_publish_index() {
    return 79
}

for send_command in SEND_MAIN SEND_SECONDARY; do
    send_id="io-${send_command,,}"
    make_send_request "$send_id" "$send_command"
    send_rc=0
    ka_ipc_handle_request "$send_id" || send_rc=$?
    send_response_dir=$(ka_ipc_response_dir "$send_id")
    assert_eq 0 "$send_rc" "$send_command remains successful when index publication is deferred"
    assert_eq OK "$(ka_read_first_line "$send_response_dir/status")" \
        "$send_command answers OK after index publication failure"
    assert_contains "$send_response_dir/message" 'runtime index publication deferred' \
        "$send_command reports deferred index publication"
done
assert_eq 1 "$SEND_MAIN_CALLS" 'SEND_MAIN is dispatched exactly once before publication failure'
assert_eq 1 "$SEND_SECONDARY_CALLS" 'SEND_SECONDARY is dispatched exactly once before publication failure'
assert_eq 1 "$KA_INDEX_STALE" 'SEND publication failure marks the runtime index stale'

# --- Stale-index retry pacing and transition diagnostics --------------------------------
FAKE_LOOP_MS=0
FAKE_NOW_S=0
FAKE_LOOP_READS=0
FAKE_PUBLISH_COUNT=0
FAKE_PUBLISH_SECONDS=()
KA_INDEX_STALE=0
# Role: Route service-loop millisecond reads to the deterministic fake clock.
ka_now_monotonic_ms() { ka_io_fake_monotonic_ms; }

# Role: Route service-loop second reads to the deterministic fake clock.
ka_now_monotonic() { ka_io_fake_monotonic; }

# Role: Route service-loop FIFO waits to the deterministic fake reader.
ka_ipc_service_read() { ka_io_fake_service_read; }

# Role: Route service-loop cadence selection to the deterministic attended fake.
ka_service_discovery_interval() { ka_io_fake_discovery_interval; }

# Role: Route service-loop target scanning to the empty fake target set.
ka_service_scan_targets() { ka_io_fake_scan_targets; }

# Role: Route service-loop runtime checks to the bounded fake lifetime.
ka_service_runtime_present() { ka_io_fake_runtime_present; }

# Role: Route service-loop index publication to the failing-then-recovering fake.
ka_state_publish_index() { ka_io_fake_publish_index; }

loop_rc=0
ka_service_loop 2>"$TEST_TMP/stale-loop.err" || loop_rc=$?
assert_eq 0 "$loop_rc" 'fake-clock service loop exits cleanly after stale-index recovery'
assert_eq '1 2 3' "${FAKE_PUBLISH_SECONDS[*]}" \
    'stale-index publication is attempted at most once per second'
loop_warnings=$(grep -Fc 'index publication failed (status 79); retrying every second' \
    "$TEST_TMP/stale-loop.err" || true)
assert_eq 1 "$loop_warnings" 'stale-index failure emits one transition warning'
loop_recoveries=$(grep -Fc 'runtime index publication recovered' "$TEST_TMP/stale-loop.err" || true)
assert_eq 1 "$loop_recoveries" 'stale-index recovery emits one informational line'

test_finish
