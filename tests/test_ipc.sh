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

test_finish
