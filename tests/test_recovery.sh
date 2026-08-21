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
dir=$(ka_state_target_dir "$uuid"); mkdir -p "$dir/messages"; ka_write_scalar "$dir/messages/001" ping
ka_state_save_target "$uuid"

# Role: Mock strict validation success to model same-login daemon crash recovery.
ka_konsole_validate_target() { return 0; }
ka_service_recover_targets
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'service recovery preserves active state'
assert_eq 317 "${KA_T_MAIN_REMAIN[$uuid]}" 'service recovery preserves main remaining time'
assert_eq 81 "${KA_T_SECONDARY_REMAIN[$uuid]}" 'service recovery preserves secondary remaining time'
assert_contains "$(ka_log_path "$uuid")" 'daemon recovered; countdown preserved' 'same-session recovery is recorded in target log'

test_finish
