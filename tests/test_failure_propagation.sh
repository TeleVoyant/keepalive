#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core

bad_parent="$TEST_TMP/request-parent"
printf x >"$bad_parent"
KA_REQUESTS_DIR="$bad_parent/requests"
rc=0
ka_ipc_new_request PING '' >/dev/null 2>"$TEST_TMP/ipc-mkdir.err" || rc=$?
assert_eq 1 "$rc" 'request directory creation failure is returned'
assert_contains "$TEST_TMP/ipc-mkdir.err" 'could not create runtime director' \
    'request directory creation failure is explained'
ka_xdg_init
ka_ensure_runtime_dirs

# Role: Return a deterministic request identifier for malformed-destination coverage.
ka_request_id() { printf directory-fail; }

# Role: Fail the first request scalar write after its private directory was created.
ka_write_scalar() { return 83; }
rc=0
ka_ipc_new_request PING '' >/dev/null 2>"$TEST_TMP/request-write.err" || rc=$?
assert_eq 1 "$rc" 'a request command directory is rejected as a scalar write failure'
assert_false 'failed request directory is cleaned up' \
    test -e "$KA_REQUESTS_DIR/directory-fail"
assert_contains "$TEST_TMP/request-write.err" 'could not write request command' \
    'request scalar write failure is explained'
source "$TEST_ROOT/lib/common.sh"

bad_response_parent="$TEST_TMP/response-parent"
printf x >"$bad_response_parent"
KA_RESPONSES_DIR="$bad_response_parent/responses"
rc=0
ka_ipc_respond response-id OK ok 2>"$TEST_TMP/response-mkdir.err" || rc=$?
assert_eq 1 "$rc" 'response directory creation failure is returned'

KA_RESPONSES_DIR="$TEST_TMP/responses"
mkdir -p "$KA_RESPONSES_DIR/message-fail/message"
rc=0
ka_ipc_respond message-fail OK ok 2>"$TEST_TMP/response-message.err" || rc=$?
assert_eq 1 "$rc" 'response message destination directory is rejected'
assert_false 'status is not committed after response message failure' \
    test -e "$KA_RESPONSES_DIR/message-fail/status"

mkdir -p "$KA_RESPONSES_DIR/status-fail/status"
rc=0
ka_ipc_respond status-fail OK ok 2>"$TEST_TMP/response-status.err" || rc=$?
assert_eq 1 "$rc" 'response status destination directory is rejected'
assert_file "$KA_RESPONSES_DIR/status-fail/message" \
    'response message is written before the status commit marker'

KA_REQUESTS_DIR="$KA_RUNTIME_DIR/requests"
KA_RESPONSES_DIR="$KA_RUNTIME_DIR/responses"
KA_CONTROL_FIFO="$TEST_TMP/missing-parent/control.fifo"
rc=0
ka_ipc_service_open >/dev/null 2>"$TEST_TMP/fifo-create.err" || rc=$?
assert_eq 1 "$rc" 'control FIFO creation failure is returned'

KA_CONTROL_FIFO="$TEST_TMP/control-file"
: >"$KA_CONTROL_FIFO"

# Role: Keep the FIFO-write probe local instead of contacting a user manager.
ka_ipc_ensure_socket_unit() { return 0; }

# Role: Simulate a failed control-line write after the FIFO descriptor opens.
ka_ipc_write_request_line() { return 74; }
rc=0
ka_ipc_signal_request probe-id || rc=$?
assert_eq 1 "$rc" 'control FIFO write failure is returned'
unset -f ka_ipc_ensure_socket_unit
source "$TEST_ROOT/lib/ipc.sh"

source "$TEST_ROOT/lib/service.sh"
lock_not_dir="$TEST_TMP/lock-not-dir"
printf x >"$lock_not_dir"
KA_RUNTIME_DIR=$lock_not_dir
rc=0
ka_service_acquire_lock 2>"$TEST_TMP/lock-open.err" || rc=$?
assert_eq 2 "$rc" 'manager lock open failure is fatal'
assert_contains "$TEST_TMP/lock-open.err" 'manager lock' \
    'manager lock open failure is explained'

lock_symlink_dir="$TEST_TMP/lock-symlink"
lock_external="$TEST_TMP/lock-external"
mkdir -p "$lock_symlink_dir"
printf 'external lock contents\n' >"$lock_external"
ln -s -- "$lock_external" "$lock_symlink_dir/manager.lock"
KA_RUNTIME_DIR=$lock_symlink_dir
rc=0
ka_service_acquire_lock 2>"$TEST_TMP/lock-symlink.err" || rc=$?
assert_eq 2 "$rc" 'a symlinked manager lock is rejected'
assert_eq 'external lock contents' "$(<"$lock_external")" \
    'manager lock acquisition never truncates a symlink target'
assert_contains "$TEST_TMP/lock-symlink.err" 'refusing unsafe manager lock' \
    'symlinked manager lock rejection is explained'

valid_lock="$TEST_TMP/valid-lock"
fakebin="$TEST_TMP/fakebin"
mkdir -p "$valid_lock" "$fakebin"
printf '#!/usr/bin/env bash\nexit 42\n' >"$fakebin/flock"
chmod +x "$fakebin/flock"
old_path=$PATH
export PATH="$fakebin:$PATH"
hash -r
KA_RUNTIME_DIR=$valid_lock
rc=0
ka_service_acquire_lock 2>"$TEST_TMP/flock.err" || rc=$?
export PATH=$old_path
hash -r
assert_eq 2 "$rc" 'fatal flock failure is distinct from lock contention'
assert_contains "$TEST_TMP/flock.err" 'status 42' 'fatal flock failure is explained'

ka_state_init_arrays
publish_handler_id='publish-handler-fail'
publish_handler_dir=$(ka_ipc_request_dir "$publish_handler_id")
mkdir -p "$publish_handler_dir"
ka_write_scalar "$publish_handler_dir/command" PING

# Role: Simulate failure while committing the client-visible runtime index.
ka_state_publish_index() { return 79; }
rc=0
ka_ipc_handle_request "$publish_handler_id" >/dev/null || rc=$?
assert_eq 79 "$rc" 'request handler propagates index publication failure'
assert_eq ERROR "$(ka_read_first_line "$KA_RESPONSES_DIR/$publish_handler_id/status")" \
    'index publication failure changes a successful command response to ERROR'
assert_eq 'could not publish the runtime index' \
    "$(ka_read_first_line "$KA_RESPONSES_DIR/$publish_handler_id/message")" \
    'index publication failure reaches the client with a precise reason'
source "$TEST_ROOT/lib/state.sh"

handler_id='response-handler-fail'
handler_dir=$(ka_ipc_request_dir "$handler_id")
mkdir -p "$handler_dir"
ka_write_scalar "$handler_dir/command" PING

# Role: Simulate an IPC response filesystem failure.
ka_ipc_respond() { return 77; }

# Role: Keep index publication out of the response-propagation probe.
ka_state_publish_index() { return 0; }
rc=0
ka_ipc_handle_request "$handler_id" >/dev/null || rc=$?
assert_eq 77 "$rc" 'request handler propagates response write failure'
source "$TEST_ROOT/lib/ipc.sh"
source "$TEST_ROOT/lib/state.sh"

# Source the public entrypoint in an informational mode so its CLI helpers become testable
# without starting a client or touching the live user manager.
source "$TEST_ROOT/keepalive" --help >/dev/null

# Role: Pretend the local daemon is available for CLI-create unit probes.
ka_cli_ensure_service() { return 0; }

# Role: Make the pre-create refresh a no-op.
ka_ipc_call() { return 0; }

# Role: Avoid reading a daemon-published index in CLI-create unit probes.
ka_tui_load_index() { return 0; }

# Role: Present the requested target as currently available.
ka_cli_status_of() { printf AVAILABLE; }

TEST_REQUEST_DIR="$TEST_TMP/config-mkdir-fail"
mkdir -p "$TEST_REQUEST_DIR"
: >"$TEST_REQUEST_DIR/config"

# Role: Return the request identifier selected by the current CLI-create probe.
ka_ipc_new_request() { printf test-request; }

# Role: Return the request directory selected by the current CLI-create probe.
ka_ipc_request_dir() { printf '%s' "$TEST_REQUEST_DIR"; }
rc=0
ka_cli_create uuid >/dev/null 2>"$TEST_TMP/create-config.err" || rc=$?
assert_eq 1 "$rc" 'CLI create returns request-config directory failure'
assert_false 'CLI create removes a request after config directory failure' \
    test -e "$TEST_REQUEST_DIR"

TEST_REQUEST_DIR="$TEST_TMP/timeout-request"

# Role: Keep profile copying local to the timeout-output probe.
ka_profile_copy_to_request() { return 0; }

# Role: Pretend request signaling succeeded in the timeout-output probe.
ka_ipc_signal_request() { return 0; }

# Role: Return the real timeout response shape while reporting failure.
ka_ipc_wait_response() {
    printf 'ERROR\tTimed out waiting for keepalive service\n'
    return 1
}
rc=0
output=$(ka_cli_create timeout-uuid) || rc=$?
assert_eq 1 "$rc" 'CLI create returns nonzero on response timeout'
assert_eq 'Timed out waiting for keepalive service' "$output" \
    'CLI create preserves timeout output for the operator'

test_finish
