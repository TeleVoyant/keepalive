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

# Validators must hand the exact reason back so IPC can return it instead of a fixed
# generic string; the operator previously had to read the journal to learn why.
ka_error_reset
assert_false 'malformed CREATE fails' ka_state_create_target 'no-such-uuid' "$bad_req"
assert_eq 'selected Konsole session is no longer available' "$KA_LAST_ERROR" \
    'refusal records an operator-facing reason for the IPC responder'
ka_error_reset
assert_eq '' "$KA_LAST_ERROR" 'the recorded reason can be cleared between operations'

ka_state_toggle_pause "$uuid"
assert_eq PAUSED "${KA_T_STATUS[$uuid]}" 'pause transition'
assert_eq 60 "${KA_T_MAIN_REMAIN[$uuid]}" 'pause preserves remaining time'
ka_state_toggle_pause "$uuid"
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'resume transition'

# Periodic health prefers the discovery snapshot so it costs no extra D-Bus calls.
# Role: Fail loudly if health validation still reaches for a live D-Bus call.
ka_konsole_validate_target() { KA_LIVE_VALIDATION_CALLS=$(( ${KA_LIVE_VALIDATION_CALLS:-0} + 1 )); return 0; }
KA_LIVE_VALIDATION_CALLS=0
KA_D_FG_PID[$uuid]=$$
ka_state_validate_targets
assert_eq 0 "$KA_LIVE_VALIDATION_CALLS" 'a discovered target is validated from the snapshot, without D-Bus'
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'snapshot validation keeps a healthy target active'
unset 'KA_D_TERM_PID[$uuid]'
ka_state_validate_targets
assert_eq 1 "$KA_LIVE_VALIDATION_CALLS" 'a target missing from discovery still falls back to a live call'
# Keep the target out of the snapshot so the strike tests below exercise the live path.
unset 'KA_D_FG_PID[$uuid]'

# Transient failures are debounced, not ignored. A call that timed out or could not be
# made proves nothing, but a bus that never returns must still end in UNAVAILABLE.
# Role: Model a bounded qdbus timeout during periodic target health validation.
ka_konsole_validate_target() { return 20; }
KEEPALIVE_VALIDATION_STRIKES=3
KA_T_STRIKES[$uuid]=0
ka_state_validate_targets
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'transient health timeout does not make target unavailable'
assert_eq 1 "${KA_T_STRIKES[$uuid]}" 'a transient failure records one strike'
ka_state_validate_targets
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'a second transient failure still retains identity'

# Role: Model an unreachable Konsole D-Bus session rather than a timeout.
ka_konsole_validate_target() { return 21; }
ka_state_validate_targets
assert_eq UNAVAILABLE "${KA_T_STATUS[$uuid]}" 'repeated unreachable validation eventually gives up'
assert_contains "$(ka_log_path "$uuid")" 'consecutive attempts' 'the giving-up reason records the strike count'

KA_T_STATUS[$uuid]=ACTIVE; KA_T_STRIKES[$uuid]=2
# Role: Model a Konsole session that becomes reachable again before the budget runs out.
ka_konsole_validate_target() { return 0; }
ka_state_validate_targets
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'recovery keeps the target active'
assert_eq 0 "${KA_T_STRIKES[$uuid]}" 'a successful validation clears accumulated strikes'
unset KEEPALIVE_VALIDATION_STRIKES
source "$TEST_ROOT/lib/konsole.sh"

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
