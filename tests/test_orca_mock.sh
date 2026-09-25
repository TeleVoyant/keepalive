#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core

if ! command -v jq >/dev/null 2>&1; then
    printf 'ok 1 - Orca adapter tests skipped: jq is not installed\n'
    TEST_COUNT=1
    test_finish
    exit
fi

export KEEPALIVE_ORCA_ENABLED=1
export KEEPALIVE_ORCA_CLI="$TEST_ROOT/tests/fixtures/orca-mock"
export KEEPALIVE_JQ
KEEPALIVE_JQ=$(command -v jq)
KA_ORCA_CLI=''
KA_ORCA_JQ=''
assert_true 'Orca adapter resolves an explicit CLI and JSON parser' ka_orca_find

discovery=$(ka_orca_discover)
IFS= read -r row <<<"$discovery"
IFS=$'\t' read -r uuid agent name directory handle pty incarnation worktree runtime host tab leaf <<<"$row"
assert_eq 'orca-runtime-1111-incarnation-2222' "$uuid" 'discovery namespaces runtime and incarnation identity'
assert_eq codex "$agent" 'discovery records Orca agent identity'
assert_eq 'Codex - Orca Project' "$name" 'discovery uses the terminal title as display metadata'
assert_eq '/work/Orca-Project' "$directory" 'discovery records the Orca worktree path'
assert_eq term_mock-agent "$handle" 'discovery records the runtime-scoped handle'

assert_true 'strict Orca validation accepts the exact recorded binding' \
    ka_orca_validate_target "$handle" "$pty" "$incarnation" "$worktree" "$runtime" "$host" "$tab" "$leaf" "$agent"

missing_binding_file="$TEST_TMP/missing-binding"
touch "$missing_binding_file"
export FAKE_ORCA_MISSING_BINDING_FILE=$missing_binding_file
if ka_orca_validate_target "$handle" "$pty" "$incarnation" "$worktree" "$runtime" "$host" "$tab" "$leaf" "$agent"; then
    validation_rc=0
else
    validation_rc=$?
fi
assert_eq 22 "$validation_rc" 'an unfamiliar Orca show schema has a dedicated indeterminate result'
assert_true 'an unfamiliar Orca schema is retryable' ka_orca_validation_is_transient "$validation_rc"
assert_false 'an unfamiliar Orca schema never consumes identity-loss strikes' \
    ka_orca_validation_consumes_strike "$validation_rc"
schema_discovery=$(ka_orca_discover)
schema_rc=0; [[ $schema_discovery == '#INCOMPLETE'$'\t'schema* ]] || schema_rc=1
assert_eq 0 "$schema_rc" 'an agent row missing a binding field fails the discovery pass closed'
rm -f -- "$missing_binding_file"
unset FAKE_ORCA_MISSING_BINDING_FILE

incarnation_file="$TEST_TMP/incarnation"
ka_write_scalar "$incarnation_file" replacement-incarnation
export FAKE_ORCA_INCARNATION_FILE=$incarnation_file
if ka_orca_validate_target "$handle" "$pty" "$incarnation" "$worktree" "$runtime" "$host" "$tab" "$leaf" "$agent"; then
    validation_rc=0
else
    validation_rc=$?
fi
assert_eq 12 "$validation_rc" 'a changed Orca process incarnation is definitive identity loss'
unset FAKE_ORCA_INCARNATION_FILE

runtime_file="$TEST_TMP/orca-runtime-id"
ka_write_scalar "$runtime_file" replacement-runtime
export FAKE_ORCA_RUNTIME_FILE=$runtime_file
if ka_orca_validate_target "$handle" "$pty" "$incarnation" "$worktree" "$runtime" "$host" "$tab" "$leaf" "$agent"; then
    validation_rc=0
else
    validation_rc=$?
fi
assert_eq 11 "$validation_rc" 'an Orca runtime restart is detected without handle rebinding'
unset FAKE_ORCA_RUNTIME_FILE

gone_file="$TEST_TMP/gone"
touch "$gone_file"
export FAKE_ORCA_GONE_FILE=$gone_file
if ka_orca_validate_target "$handle" "$pty" "$incarnation" "$worktree" "$runtime" "$host" "$tab" "$leaf" "$agent"; then
    validation_rc=0
else
    validation_rc=$?
fi
assert_eq 10 "$validation_rc" 'a confirmed gone Orca terminal is definitive'
rm -f -- "$gone_file"
unset FAKE_ORCA_GONE_FILE

offline_file="$TEST_TMP/offline"
touch "$offline_file"
export FAKE_ORCA_ERROR_FILE=$offline_file
if ka_orca_validate_target "$handle" "$pty" "$incarnation" "$worktree" "$runtime" "$host" "$tab" "$leaf" "$agent"; then
    validation_rc=0
else
    validation_rc=$?
fi
assert_eq 21 "$validation_rc" 'an unreachable Orca runtime remains transient'
rm -f -- "$offline_file"
unset FAKE_ORCA_ERROR_FILE

hang_file="$TEST_TMP/hang"
touch "$hang_file"
export FAKE_ORCA_HANG_FILE=$hang_file
export KEEPALIVE_ORCA_TIMEOUT=1
if ka_orca_validate_target "$handle" "$pty" "$incarnation" "$worktree" "$runtime" "$host" "$tab" "$leaf" "$agent"; then
    validation_rc=0
else
    validation_rc=$?
fi
assert_eq 20 "$validation_rc" 'a bounded Orca CLI expiry is classified as a timeout'
rm -f -- "$hang_file"
unset FAKE_ORCA_HANG_FILE KEEPALIVE_ORCA_TIMEOUT

send_log="$TEST_TMP/send.log"
export FAKE_ORCA_SEND_LOG=$send_log
assert_true 'Orca message delivery is accepted' ka_orca_deliver "$handle" MESSAGE_ENTER 'ping from test'
assert_contains "$send_log" $'text_set=1\tenter=1\ttext=ping from test' \
    'message and Enter use one atomic Orca CLI request'
assert_true 'Orca enter-only delivery is accepted' ka_orca_deliver "$handle" ENTER_ONLY ''
assert_contains "$send_log" $'text_set=0\tenter=1\ttext=' 'enter-only omits message text'

send_fail_file="$TEST_TMP/send-fail"
touch "$send_fail_file"
export FAKE_ORCA_SEND_FAIL_FILE=$send_fail_file
assert_false 'an Orca refusal propagates as transport failure' \
    ka_orca_deliver "$handle" MESSAGE_ENTER ping
rm -f -- "$send_fail_file"
unset FAKE_ORCA_SEND_FAIL_FILE

ka_state_init_arrays
ka_profile_init_defaults
KA_KONSOLE_ENABLED=0
KA_ORCA_ENABLED=1
assert_true 'a complete Orca pass commits through the generic discovery state' ka_state_refresh_discovery
assert_eq 1 "${#KA_D_UUIDS[@]}" 'ordinary Orca shell terminals are not discovered as agents'
assert_eq orca "${KA_D_BACKEND[$uuid]}" 'discovery records the Orca backend discriminator'
assert_eq Codex "${KA_D_TYPE[$uuid]}" 'Orca agent identity is normalized for presentation'

request="$TEST_TMP/request"
ka_profile_copy_to_request "$request"
ka_state_create_target "$uuid" "$request"
assert_eq orca "${KA_T_BACKEND[$uuid]}" 'CREATE retains the Orca backend'
assert_eq "$incarnation" "${KA_T_ORCA_INCARNATION[$uuid]}" 'CREATE retains exact Orca incarnation identity'
assert_contains "$(target_dir "$uuid")/state.tsv" $'backend\torca' 'checkpoint persists the backend discriminator'
assert_contains "$(target_dir "$uuid")/state.tsv" $'orca_runtime\truntime-1111' 'checkpoint persists the Orca runtime binding'

ka_state_init_arrays
assert_true 'an Orca checkpoint reloads after a daemon restart' \
    ka_state_load_target_dir "$(target_dir "$uuid")"
assert_eq orca "${KA_T_BACKEND[$uuid]}" 'recovery restores the Orca backend'
assert_eq "$handle" "${KA_T_ORCA_HANDLE[$uuid]}" 'recovery restores the runtime-scoped handle'

checkpoint="$(target_dir "$uuid")/state.tsv"
valid_checkpoint="$TEST_TMP/orca-state.valid"
cp -- "$checkpoint" "$valid_checkpoint"
sed $'s/^backend\torca$/backend\tfuture-orca/' "$valid_checkpoint" >"$checkpoint"
ka_state_init_arrays
assert_false 'an unknown persisted backend contract is rejected' \
    ka_state_load_target_dir "$(target_dir "$uuid")"
assert_eq 'unsupported terminal backend: future-orca' "$KA_STATE_LOAD_ERROR" \
    'backend rejection preserves a precise quarantine reason'
sed $'s/^orca_runtime\truntime-1111$/orca_runtime\trebound-runtime/' "$valid_checkpoint" >"$checkpoint"
ka_state_init_arrays
assert_false 'a persisted Orca target cannot be rebound to a different runtime' \
    ka_state_load_target_dir "$(target_dir "$uuid")"
assert_eq 'Orca target ID does not match its runtime/incarnation binding' "$KA_STATE_LOAD_ERROR" \
    'runtime rebinding is rejected before recovery can send input'
cp -- "$valid_checkpoint" "$checkpoint"
ka_state_init_arrays
assert_true 'the valid Orca checkpoint still reloads after rejection tests' \
    ka_state_load_target_dir "$(target_dir "$uuid")"

touch "$missing_binding_file"
export FAKE_ORCA_MISSING_BINDING_FILE=$missing_binding_file
export KEEPALIVE_ORCA_SNAPSHOT_MAX_AGE=1 KEEPALIVE_VALIDATION_STRIKES=2
KA_DISCOVERY_STAMP_ORCA=0
ka_state_validate_targets
ka_state_validate_targets
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" \
    'repeated Orca schema incompatibility never becomes sticky unavailable'
assert_eq 0 "${KA_T_STRIKES[$uuid]}" 'schema incompatibility does not accumulate reachability strikes'
rm -f -- "$missing_binding_file"
unset FAKE_ORCA_MISSING_BINDING_FILE KEEPALIVE_ORCA_SNAPSHOT_MAX_AGE KEEPALIVE_VALIDATION_STRIKES
assert_true 'generic transport validation dispatches to Orca' ka_transport_validate_target "$uuid"
assert_true 'scheduler delivery dispatches to Orca' ka_scheduler_send_main "$uuid" MANUAL
assert_contains "$send_log" $'text_set=1\tenter=1\ttext=ping' \
    'scheduler sends the stored rotation message through Orca'
scheduler_fail_file="$TEST_TMP/scheduler-send-fail"
touch "$scheduler_fail_file"
export FAKE_ORCA_SEND_FAIL_FILE=$scheduler_fail_file
assert_false 'scheduler propagates an Orca transport refusal' ka_scheduler_send_main "$uuid" MANUAL
assert_eq 'Orca rejected the main send (transport failure)' "$KA_LAST_ERROR" \
    'scheduler reports the selected backend in its failure reason'
rm -f -- "$scheduler_fail_file"
unset FAKE_ORCA_SEND_FAIL_FILE
assert_true 'recovery can rebuild the live Orca discovery snapshot' ka_state_refresh_discovery

bad_schema_file="$TEST_TMP/bad-schema"
touch "$bad_schema_file"
export FAKE_ORCA_BAD_SCHEMA_FILE=$bad_schema_file
konsole_uuid='konsole-isolation-row'
# Role: Emit a complete Konsole snapshot while the Orca adapter is intentionally failing.
ka_konsole_discover() {
    printf '%s\tCodex\tKonsole Agent\t/work/konsole\torg.kde.konsole-42\t/Sessions/7\t111\t222\t333\t444\tcodex\n' \
        "$konsole_uuid"
    printf '#COMPLETE\n'
}
KA_KONSOLE_ENABLED=1
assert_false 'an unknown Orca JSON schema marks only that backend pass incomplete' ka_state_refresh_discovery
assert_eq konsole "${KA_D_BACKEND[$konsole_uuid]}" \
    'a healthy Konsole snapshot still commits during an Orca schema failure'
assert_eq orca "${KA_D_BACKEND[$uuid]}" 'the previous Orca snapshot survives an incomplete future schema'
assert_eq 2 "${#KA_D_UUIDS[@]}" 'backend snapshots remain isolated instead of replacing each other'
assert_eq Orca "$KA_DISCOVERY_STALE_BACKENDS" 'the stale backend is identified for diagnostics'
rm -f -- "$bad_schema_file"
unset FAKE_ORCA_BAD_SCHEMA_FILE

test_finish
