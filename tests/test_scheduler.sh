#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
ka_state_init_arrays

uuid='aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee'
KA_T_UUIDS=("$uuid")
KA_T_TYPE[$uuid]='Claude'; KA_T_NAME[$uuid]='Test'; KA_T_DIR[$uuid]='/tmp/Test'
KA_T_SERVICE[$uuid]='svc'; KA_T_PATH[$uuid]='/Sessions/1'; KA_T_TERM_PID[$uuid]=$$
KA_T_AI_PID[$uuid]=$$; KA_T_AI_START[$uuid]=$(ka_proc_starttime $$); KA_T_STATUS[$uuid]=ACTIVE
KA_T_MODE[$uuid]=MESSAGE_ENTER; KA_T_NOTIFY[$uuid]=0; KA_T_MAIN_INTERVAL[$uuid]=10; KA_T_MAIN_REMAIN[$uuid]=1
KA_T_MAIN_INDEX[$uuid]=0; KA_T_SECONDARY_ENABLED[$uuid]=1; KA_T_SECONDARY_INTERVAL[$uuid]=5
KA_T_SECONDARY_REMAIN[$uuid]=3; KA_T_SECONDARY_MESSAGE[$uuid]='nudge'; KA_T_LAST_SEEN[$uuid]=''; KA_T_REASON[$uuid]=''
dir=$(ka_state_target_dir "$uuid"); mkdir -p "$dir/messages"; ka_write_scalar "$dir/messages/001" one; ka_write_scalar "$dir/messages/002" two

# Role: Mock target validation so scheduler tests do not require live Konsole D-Bus.
ka_konsole_validate_target() { return 0; }
DELIVERIES=()
# Role: Capture scheduler deliveries in memory instead of sending D-Bus input.
ka_konsole_deliver() { DELIVERIES+=("$3:$4"); return 0; }
# Role: Suppress desktop notifications during scheduler unit tests.
ka_notify_sent() { :; }

ka_scheduler_send_main "$uuid" MANUAL
assert_eq 1 "${KA_T_MAIN_INDEX[$uuid]}" 'message mode consumes and advances rotation'
assert_eq 10 "${KA_T_MAIN_REMAIN[$uuid]}" 'manual main send resets main countdown'

KA_T_MODE[$uuid]=ENTER_ONLY
ka_scheduler_send_main "$uuid" MANUAL
assert_eq 1 "${KA_T_MAIN_INDEX[$uuid]}" 'enter-only send does not consume queued message'

KA_T_MAIN_REMAIN[$uuid]=7
ka_scheduler_send_secondary "$uuid" MANUAL
assert_eq 7 "${KA_T_MAIN_REMAIN[$uuid]}" 'secondary send preserves main remaining time'
assert_eq 5 "${KA_T_SECONDARY_REMAIN[$uuid]}" 'secondary send resets only secondary timer'

KA_T_MAIN_REMAIN[$uuid]=7; KA_T_SECONDARY_REMAIN[$uuid]=4
ka_scheduler_tick 30
assert_eq 7 "${KA_T_MAIN_REMAIN[$uuid]}" 'large suspend-like gap preserves main timer'
assert_eq 4 "${KA_T_SECONDARY_REMAIN[$uuid]}" 'large suspend-like gap preserves secondary timer'

test_finish
