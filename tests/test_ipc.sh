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

# The control read is the daemon loop's only pacing, so an immediate return must be
# distinguishable from an idle timeout; otherwise a broken descriptor becomes a busy spin
# that never crashes and so never looks unhealthy.
pacing_fifo="$TEST_TMP/pacing.fifo"
mkfifo -m 600 "$pacing_fifo"
exec {KA_CONTROL_FD}<>"$pacing_fifo"
# Statuses are captured inline rather than through a command substitution: a subshell
# brings its own view of the descriptor table, which is exactly what is under test here.
read_rc=0; ka_ipc_service_read 0.10 2>/dev/null || read_rc=$?
assert_eq 1 "$read_rc" 'an idle timeout is reported as a timeout'

printf 'REQUEST xyz\n' >&"$KA_CONTROL_FD"
read_rc=0; ka_ipc_service_read 0.10 2>/dev/null || read_rc=$?
assert_eq 0 "$read_rc" 'an available line is reported as success'
assert_eq 'REQUEST xyz' "$KA_IPC_LINE" 'the line is delivered to the caller'

# A timeout can expire after the first bytes of a line were consumed; Bash keeps them in
# the variable but reports the timeout. Simulate it deterministically: one byte now, the
# rest after the timeout. The line must be completed, not dropped and left as garbage.
# Timer slack once made this land on about one request in twenty on a real system.
printf 'R' >&"$KA_CONTROL_FD"
( sleep 0.30; printf 'EQUEST split\n' >"$pacing_fifo" ) &
writer_pid=$!
read_rc=0; ka_ipc_service_read 0.10 2>/dev/null || read_rc=$?
wait "$writer_pid" 2>/dev/null || true
assert_eq 0 "$read_rc" 'a line split across a read timeout is completed rather than dropped'
assert_eq 'REQUEST split' "$KA_IPC_LINE" 'the completed line carries every byte of the request'
read_rc=0; ka_ipc_service_read 0.10 2>/dev/null || read_rc=$?
assert_eq 1 "$read_rc" 'no garbage remainder is left for the next read'

# Two ways the read can return immediately, both of which would remove the loop's pacing:
# a descriptor that cannot be read at all, and one already at end of file.
exec {KA_CONTROL_FD}>&-
KA_CONTROL_FD=99
read_rc=0; ka_ipc_service_read 0.10 2>/dev/null || read_rc=$?
assert_eq 2 "$read_rc" 'an unreadable descriptor is reported as abnormal, not as a timeout'

: >"$TEST_TMP/empty"
exec {KA_CONTROL_FD}<"$TEST_TMP/empty"
read_rc=0; ka_ipc_service_read 0.10 2>/dev/null || read_rc=$?
assert_eq 2 "$read_rc" 'a descriptor at end of file is reported as abnormal'
exec {KA_CONTROL_FD}<&-

test_finish
