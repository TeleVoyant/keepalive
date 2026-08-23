#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
ka_state_init_arrays
ka_profile_init_defaults
ka_ipc_service_open

id1=$(ka_ipc_new_request PING '')
id2=$(ka_ipc_new_request PING '')
# Feed two atomic request IDs through the same FIFO to model multiple clients.
printf 'REQUEST %s\nREQUEST %s\n' "$id1" "$id2" >"$KA_CONTROL_FIFO" &
writer=$!
ka_ipc_service_read 1; ka_ipc_handle_line "$KA_IPC_LINE"
ka_ipc_service_read 1; ka_ipc_handle_line "$KA_IPC_LINE"
wait "$writer"
assert_eq OK "$(ka_read_first_line "$(ka_ipc_response_dir "$id1")/status")" 'first client request receives response'
assert_eq OK "$(ka_read_first_line "$(ka_ipc_response_dir "$id2")/status")" 'second client request receives response'

# A FIFO whose reader has gone away must not block the client. Opening write-only blocks
# until a reader appears, which froze the client with no output and no timeout anywhere.
orphan="$TEST_TMP/orphan.fifo"
mkfifo -m 600 "$orphan"
KA_CONTROL_FIFO=$orphan
start=$SECONDS
assert_true 'signalling an unread FIFO returns instead of blocking' ka_ipc_signal_request 'probe-id'
assert_true 'it returns promptly' [ $((SECONDS - start)) -lt 5 ]

# An unreachable daemon must explain itself; callers print whatever follows the tab and
# used to render "service unavailable:" with nothing after it.
KA_CONTROL_FIFO="$TEST_TMP/absent.fifo"
reply=$(ka_ipc_call PING '' 2>/dev/null || true)
assert_eq ERROR "${reply%%$'\t'*}" 'an unreachable daemon reports an error status'
assert_true 'the failure carries a reason' [ -n "${reply#*$'\t'}" ]

KA_CONTROL_FIFO="$TEST_TMP/absent.fifo"
KEEPALIVE_RESPONSE_TIMEOUT_MS=250
start=$SECONDS
ka_ipc_wait_response 'no-such-request' >/dev/null 2>&1 || true
assert_true 'the response wait honours its configured budget' [ $((SECONDS - start)) -lt 5 ]
unset KEEPALIVE_RESPONSE_TIMEOUT_MS

test_finish
