#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
source "$TEST_ROOT/lib/service.sh"
ka_state_init_arrays

uuid='12121212-3434-4567-8787-909090909090'
KA_T_UUIDS=("$uuid")
KA_T_TYPE[$uuid]='Claude'; KA_T_NAME[$uuid]='Recovery'; KA_T_DIR[$uuid]='/work/Recovery'
KA_T_SERVICE[$uuid]='svc'; KA_T_PATH[$uuid]='/Sessions/9'; KA_T_TERM_PID[$uuid]=$$
KA_T_AI_PID[$uuid]=$$; KA_T_AI_START[$uuid]=$(ka_proc_starttime $$); KA_T_STATUS[$uuid]=ACTIVE
KA_T_MODE[$uuid]=MESSAGE_ENTER; KA_T_NOTIFY[$uuid]=0; KA_T_MAIN_INTERVAL[$uuid]=1500; KA_T_MAIN_REMAIN[$uuid]=317
KA_T_MAIN_INDEX[$uuid]=0; KA_T_SECONDARY_ENABLED[$uuid]=1; KA_T_SECONDARY_INTERVAL[$uuid]=600
KA_T_SECONDARY_REMAIN[$uuid]=81; KA_T_SECONDARY_MESSAGE[$uuid]='nudge'; KA_T_LAST_SEEN[$uuid]=''; KA_T_REASON[$uuid]=''
dir=$(target_dir "$uuid"); mkdir -p "$dir/messages"; ka_write_scalar "$dir/messages/001" ping
ka_state_save_target "$uuid"

VALIDATION_RC=0
# Role: Mock strict validation outcomes for same-login daemon crash recovery.
ka_konsole_validate_target() { return "$VALIDATION_RC"; }
ka_service_recover_targets
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'service recovery preserves active state'
assert_eq 317 "${KA_T_MAIN_REMAIN[$uuid]}" 'service recovery preserves main remaining time'
assert_eq 81 "${KA_T_SECONDARY_REMAIN[$uuid]}" 'service recovery preserves secondary remaining time'
assert_contains "$(ka_log_path "$uuid")" 'daemon recovered; countdown preserved' 'same-session recovery is recorded in target log'

VALIDATION_RC=20
ka_service_recover_targets
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'transient recovery validation timeout does not make target unavailable'
assert_contains "$(ka_log_path "$uuid")" 'recovery validation deferred' 'transient recovery validation timeout is logged as deferred'

# Periodic daemon work must survive a transient I/O failure. Unguarded, the loop runs
# under `set -e`, so one failed write aborted the daemon and Restart=on-failure retried
# until the start limit tripped and the unit stayed dead.
source "$TEST_ROOT/lib/service.sh"
# Role: Stand in for a periodic task that fails.
failing_task() { return 7; }
assert_true 'a failing periodic task does not abort the daemon' ka_service_try 'probe' failing_task
warned=$(ka_service_try 'probe' failing_task 2>&1)
assert_eq 1 "$(grep -c 'status 7' <<<"$warned")" 'the failure is reported with its real status'
assert_eq '' "$(ka_service_try 'probe' true 2>&1)" 'a succeeding task stays quiet' 

# The runtime directory disappearing means the session ended, not an error to retry.
assert_true 'a present runtime directory is detected' ka_service_runtime_present
KA_RUNTIME_DIR="$TEST_TMP/gone"
assert_false 'a vanished runtime directory is detected' ka_service_runtime_present

test_finish
