#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
ka_state_init_arrays
ka_profile_init_defaults

uuid='11111111-2222-4333-8444-555555555555'
KA_D_UUIDS=("$uuid")
KA_D_TYPE[$uuid]='Claude'
KA_D_NAME[$uuid]='Avela'
KA_D_DIR[$uuid]='/work/Avela'
KA_D_SERVICE[$uuid]='org.kde.konsole-123'
KA_D_PATH[$uuid]='/Sessions/1'
KA_D_TERM_PID[$uuid]=$$
KA_D_AI_PID[$uuid]=$$
KA_D_AI_START[$uuid]=$(ka_proc_starttime $$)

bad_req="$TEST_TMP/gapped-config"
ka_profile_copy_to_request "$bad_req"
ka_write_scalar "$bad_req/main_interval" 42
mv -- "$bad_req/messages/001" "$bad_req/messages/002"
assert_false 'CREATE rejects a non-canonical main-message rotation' ka_state_create_target "$uuid" "$bad_req"
assert_false 'rejected CREATE leaves no monitored target state' ka_state_has_target "$uuid"
assert_eq 1500 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'rejected CREATE leaves the persistent profile unchanged'

req="$TEST_TMP/config"
ka_profile_copy_to_request "$req"
ka_write_scalar "$req/main_interval" 60
ka_write_scalar "$req/messages/001" 'continue; $(do-not-run)'
ka_state_create_target "$uuid" "$req"
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'new target starts active'
assert_eq 60 "${KA_T_MAIN_REMAIN[$uuid]}" 'new target countdown starts at interval'
assert_eq 'Avela' "${KA_T_NAME[$uuid]}" 'directory basename name is retained'
assert_eq 'continue; $(do-not-run)' "$(ka_state_message_at "$uuid" 0)" 'target message remains literal data'
assert_file "$(ka_state_target_dir "$uuid")/state.tsv" 'target checkpoint written'

bad_update="$TEST_TMP/gapped-update"
ka_state_copy_target_to_request "$uuid" "$bad_update"
ka_write_scalar "$bad_update/main_interval" 99
mv -- "$bad_update/messages/001" "$bad_update/messages/002"
assert_false 'CONFIGURE rejects a non-canonical main-message rotation' ka_state_configure_target "$uuid" "$bad_update"
assert_eq 60 "${KA_T_MAIN_INTERVAL[$uuid]}" 'rejected CONFIGURE leaves selected target settings unchanged'
assert_eq 60 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'rejected CONFIGURE leaves persistent profile unchanged'

ka_state_toggle_pause "$uuid"
assert_eq PAUSED "${KA_T_STATUS[$uuid]}" 'pause transition'
assert_eq 60 "${KA_T_MAIN_REMAIN[$uuid]}" 'pause preserves remaining time'
ka_state_toggle_pause "$uuid"
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'resume transition'

ka_state_mark_unavailable "$uuid" 'AI process exited'
assert_eq UNAVAILABLE "${KA_T_STATUS[$uuid]}" 'target loss is sticky unavailable'
assert_contains "$(ka_log_path "$uuid")" 'UNAVAILABLE' 'unavailable event is logged per target'

# A newly launched terminal with the same directory/name but a different UUID is a new identity.
new_uuid='99999999-8888-4777-8666-555555555555'
KA_D_UUIDS+=("$new_uuid")
KA_D_TYPE[$new_uuid]='Claude'
KA_D_NAME[$new_uuid]='Avela'
KA_D_DIR[$new_uuid]='/work/Avela'
ka_state_publish_index
assert_contains "$KA_INDEX_FILE" "$uuid" 'old unavailable UUID remains visible in merged index'
assert_contains "$KA_INDEX_FILE" $'99999999-8888-4777-8666-555555555555\tClaude\tAvela\t/work/Avela\tAVAILABLE' 'replacement terminal is a separate AVAILABLE UUID, never reattached'
ka_state_delete_target "$uuid"
assert_false 'delete removes target record' test -d "$(ka_state_target_dir "$uuid")"
assert_false 'delete removes independent runtime history' test -f "$(ka_log_path "$uuid")"

test_finish
