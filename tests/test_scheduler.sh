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

VALIDATION_RC=0
# Role: Mock target validation so scheduler tests can select success or timeout.
ka_konsole_validate_target() { return "$VALIDATION_RC"; }
DELIVERIES=()
DELIVERY_RC=0
SUBMIT_ONLY_SEEN=''
# Role: Capture scheduler deliveries in memory instead of sending D-Bus input.
ka_konsole_deliver() { DELIVERIES+=("$3:$4"); SUBMIT_ONLY_SEEN=${5:-0}; return "$DELIVERY_RC"; }
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

KA_T_MODE[$uuid]=MESSAGE_ENTER
KA_T_MAIN_REMAIN[$uuid]=1
DELIVERY_RC=1
assert_false 'failed main transport returns failure to its caller' ka_scheduler_send_main "$uuid" MANUAL
assert_eq 10 "${KA_T_MAIN_REMAIN[$uuid]}" 'failed main transport still resets its consumed timer event'
assert_eq 1 "${KA_T_MAIN_INDEX[$uuid]}" 'failed main transport does not advance message rotation'
assert_contains "$(ka_log_path "$uuid")" $'MAIN\ttwo\tFAILED · manual' 'failed main transport is logged explicitly'

KA_T_MAIN_REMAIN[$uuid]=7
KA_T_SECONDARY_REMAIN[$uuid]=1
assert_false 'failed secondary transport returns failure to its caller' ka_scheduler_send_secondary "$uuid" MANUAL
assert_eq 7 "${KA_T_MAIN_REMAIN[$uuid]}" 'failed secondary transport still preserves main remaining time'
assert_eq 5 "${KA_T_SECONDARY_REMAIN[$uuid]}" 'failed secondary transport resets only its consumed timer event'

DELIVERY_RC=0

VALIDATION_RC=20
KA_T_MAIN_REMAIN[$uuid]=1
assert_false 'transient validation timeout returns failure without losing target identity' ka_scheduler_send_main "$uuid" MANUAL
assert_eq ACTIVE "${KA_T_STATUS[$uuid]}" 'transient validation timeout leaves target active'
assert_eq 10 "${KA_T_MAIN_REMAIN[$uuid]}" 'transient validation timeout resets consumed main event'
assert_eq 1 "${KA_T_MAIN_INDEX[$uuid]}" 'transient validation timeout preserves main rotation'
assert_contains "$(ka_log_path "$uuid")" 'Konsole D-Bus validation timed out' 'transient validation timeout is logged'
VALIDATION_RC=0

KA_T_MAIN_REMAIN[$uuid]=7; KA_T_SECONDARY_REMAIN[$uuid]=4
ka_scheduler_tick -30
assert_eq 7 "${KA_T_MAIN_REMAIN[$uuid]}" 'backward monotonic jump preserves main timer'
assert_eq 4 "${KA_T_SECONDARY_REMAIN[$uuid]}" 'backward monotonic jump preserves secondary timer'
assert_contains "$(ka_log_path "$uuid")" 'monotonic clock moved backward 30s' 'backward monotonic jump is recorded'

ka_scheduler_tick 30
assert_eq 7 "${KA_T_MAIN_REMAIN[$uuid]}" 'large suspend-like gap preserves main timer'
assert_eq 4 "${KA_T_SECONDARY_REMAIN[$uuid]}" 'large suspend-like gap preserves secondary timer'

# A message that reached the terminal without its submit must not be sent twice.
KA_T_MODE[$uuid]=MESSAGE_ENTER
KA_T_PENDING_SUBMIT[$uuid]=0
DELIVERY_RC=3
assert_false 'a partial delivery reports failure' ka_scheduler_send_main "$uuid" MANUAL
assert_eq 1 "${KA_T_PENDING_SUBMIT[$uuid]}" 'a partial delivery records that a submit is owed'
assert_contains "$(ka_log_path "$uuid")" 'submit owed' 'the event log distinguishes a partial delivery'
assert_eq 'message delivered but submit failed; the next attempt will only submit' "$KA_LAST_ERROR" \
    'the client is told a submit is owed rather than a generic transport failure'

DELIVERY_RC=0
before=${KA_T_MAIN_INDEX[$uuid]}
ka_scheduler_send_main "$uuid" MANUAL
assert_eq 1 "$SUBMIT_ONLY_SEEN" 'the retry submits the pending line instead of resending the message'
assert_eq 0 "${KA_T_PENDING_SUBMIT[$uuid]}" 'a successful submit clears the pending state'
assert_eq "$(( (before + 1) % 2 ))" "${KA_T_MAIN_INDEX[$uuid]}" 'completing a pending submit advances the rotation'

ka_scheduler_send_main "$uuid" MANUAL
assert_eq 0 "$SUBMIT_ONLY_SEEN" 'the following send delivers a full message again'

# `e` sends one Enter now and resumes normal delivery; it is not a mode toggle.
KA_T_MODE[$uuid]=ENTER_ONLY
KA_T_MAIN_REMAIN[$uuid]=3
KA_T_PENDING_SUBMIT[$uuid]=1
before_index=${KA_T_MAIN_INDEX[$uuid]}
DELIVERIES=()
assert_true 'a one-shot Enter is delivered' ka_scheduler_send_enter_once "$uuid" MANUAL
assert_eq 'ENTER_ONLY:' "${DELIVERIES[0]}" 'the one-shot sends only a submit, with no message'
assert_eq MESSAGE_ENTER "${KA_T_MODE[$uuid]}" 'the one-shot resumes message+enter delivery'
assert_eq 10 "${KA_T_MAIN_REMAIN[$uuid]}" 'the one-shot resets the main countdown'
assert_eq "$before_index" "${KA_T_MAIN_INDEX[$uuid]}" 'the one-shot never consumes a queued message'
assert_eq 0 "${KA_T_PENDING_SUBMIT[$uuid]}" 'a bare Enter completes any pending submit'

# `E` pins enter-only; setting a mode is explicit, not a flip.
assert_true 'enter-only can be set explicitly' ka_state_set_mode "$uuid" ENTER_ONLY
assert_eq ENTER_ONLY "${KA_T_MODE[$uuid]}" 'the requested mode is applied'
assert_true 'setting the current mode again is a no-op' ka_state_set_mode "$uuid" ENTER_ONLY
assert_false 'an invalid mode is refused' ka_state_set_mode "$uuid" NONSENSE
KA_T_MODE[$uuid]=MESSAGE_ENTER

# The secondary prompt is a one-shot nudge, not a repeating timer.
KA_T_STATUS[$uuid]=ACTIVE
KA_T_SECONDARY_ENABLED[$uuid]=1
KA_T_SECONDARY_DONE[$uuid]=0
KA_T_SECONDARY_REMAIN[$uuid]=1
KA_T_MAIN_REMAIN[$uuid]=999
KA_T_MAIN_INTERVAL[$uuid]=999
DELIVERIES=()
ka_scheduler_tick 1
assert_eq 1 "${#DELIVERIES[@]}" 'the secondary fires when it first becomes due'
assert_eq 1 "${KA_T_SECONDARY_DONE[$uuid]}" 'an automatic secondary marks itself done'

KA_T_SECONDARY_REMAIN[$uuid]=1
DELIVERIES=()
ka_scheduler_tick 1
assert_eq 0 "${#DELIVERIES[@]}" 'the secondary does not fire again once it has been sent'

DELIVERIES=()
ka_scheduler_send_secondary "$uuid" MANUAL
assert_eq 1 "${#DELIVERIES[@]}" 'a manual secondary send still works after the one-shot'
assert_eq 1 "${KA_T_SECONDARY_DONE[$uuid]}" 'a manual send does not re-arm the one-shot'

test_finish
