#!/usr/bin/env bash
# Countdown-preserving CONFIGURE, rotation identity, owner, rollback, and profile policy.
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
ka_state_init_arrays
ka_profile_init_defaults

# Keep an uninstrumented copy so rollback tests can count checkpoint saves while still
# exercising the exact production writer.
saved_state_writer="$TEST_TMP/state-writer-original.sh"
declare -f ka_state_save_target \
    | sed '1s/^ka_state_save_target/ka_state_save_target_uninstrumented/' > "$saved_state_writer"
# shellcheck disable=SC1090
source "$saved_state_writer"
COUNT_STATE_SAVES=0
STATE_SAVE_COUNT=0

# Role: Count selected checkpoint saves and delegate to the production writer.
ka_state_save_target() {
    if ((COUNT_STATE_SAVES == 1)); then STATE_SAVE_COUNT=$((STATE_SAVE_COUNT + 1)); fi
    ka_state_save_target_uninstrumented "$@"
}

TIMER_CASE_ID=1

# Role: Allocate a unique valid UUID for an isolated countdown scenario.
next_timer_uuid() {
    printf -v REPLY 'a1000000-0000-4000-8000-%012d' "$TIMER_CASE_ID"
    TIMER_CASE_ID=$((TIMER_CASE_ID + 1))
}

# Role: Seed a valid persisted target with explicit scheduler state and two main messages.
seed_timer_target() {
    local uuid=$1 status=$2 main_interval=$3 main_remaining=$4 main_index=$5
    local secondary_enabled=$6 secondary_interval=$7 secondary_remaining=$8 secondary_done=$9
    shift 9
    local pending_owner=$1 mode=$2 notifications=$3 secondary_message=$4 target_dir
    ka_state_register_uuid "$uuid"
    KA_T_BACKEND[$uuid]=konsole
    KA_T_TYPE[$uuid]=Claude
    KA_T_NAME[$uuid]="Timer case $TIMER_CASE_ID"
    KA_T_DIR[$uuid]=/work/configure-timers
    KA_T_SERVICE[$uuid]=org.kde.konsole-101
    KA_T_PATH[$uuid]=/Sessions/1
    KA_T_TERM_PID[$uuid]=1
    KA_T_AI_PID[$uuid]=1
    KA_T_AI_START[$uuid]=1
    KA_T_STATUS[$uuid]=$status
    KA_T_MODE[$uuid]=$mode
    KA_T_NOTIFY[$uuid]=$notifications
    KA_T_MAIN_INTERVAL[$uuid]=$main_interval
    KA_T_MAIN_REMAIN[$uuid]=$main_remaining
    KA_T_MAIN_INDEX[$uuid]=$main_index
    KA_T_SECONDARY_ENABLED[$uuid]=$secondary_enabled
    KA_T_SECONDARY_INTERVAL[$uuid]=$secondary_interval
    KA_T_SECONDARY_REMAIN[$uuid]=$secondary_remaining
    KA_T_SECONDARY_DONE[$uuid]=$secondary_done
    KA_T_SECONDARY_MESSAGE[$uuid]=$secondary_message
    KA_T_LAST_SEEN[$uuid]=''
    KA_T_REASON[$uuid]=''
    KA_T_PENDING_SUBMIT[$uuid]=$pending_owner
    ka_state_target_dir "$uuid"
    target_dir=$REPLY
    mkdir -p -- "$target_dir/messages"
    ka_write_scalar "$target_dir/messages/001" main-one
    ka_write_scalar "$target_dir/messages/002" main-two
    ka_state_save_target "$uuid"
}

# Role: Copy a target into a valid CONFIGURE request that will not update the global profile.
make_timer_request() {
    local uuid=$1 request_dir=$2
    ka_state_copy_target_to_request "$uuid" "$request_dir"
    ka_write_scalar "$request_dir/profile_update" 0
}

# Role: Create one valid discovered terminal identity for CREATE policy tests.
seed_discovered_session() {
    local uuid=$1
    KA_D_TYPE[$uuid]=Claude
    KA_D_NAME[$uuid]="Create policy $uuid"
    KA_D_DIR[$uuid]=/work/create-profile-policy
    KA_D_SERVICE[$uuid]=org.kde.konsole-102
    KA_D_PATH[$uuid]=/Sessions/2
    KA_D_TERM_PID[$uuid]=1
    KA_D_AI_PID[$uuid]=1
    KA_D_AI_START[$uuid]=1
}

# Role: Run one secondary transition row and assert its timer and one-shot result.
run_secondary_case() {
    local label=$1 old_enabled=$2 old_interval=$3 old_remaining=$4 old_done=$5
    local old_message=$6 new_enabled=$7 new_interval=$8 new_message=$9
    shift 9
    local expected_remaining=$1 expected_done=$2 uuid request_dir
    next_timer_uuid; uuid=$REPLY
    seed_timer_target "$uuid" ACTIVE 100 30 0 "$old_enabled" "$old_interval" \
        "$old_remaining" "$old_done" 0 MESSAGE_ENTER 0 "$old_message"
    request_dir="$TEST_TMP/secondary-$TIMER_CASE_ID"
    make_timer_request "$uuid" "$request_dir"
    ka_write_scalar "$request_dir/secondary_enabled" "$new_enabled"
    ka_write_scalar "$request_dir/secondary_interval" "$new_interval"
    ka_write_scalar "$request_dir/secondary_message" "$new_message"
    ka_state_configure_target "$uuid" "$request_dir"
    assert_eq "$expected_remaining" "${KA_T_SECONDARY_REMAIN[$uuid]}" "$label: secondary remaining"
    assert_eq "$expected_done" "${KA_T_SECONDARY_DONE[$uuid]}" "$label: secondary done marker"
}

# Role: Exercise main-message logical identity and prove whether messages/ was rewritten.
run_rotation_case() {
    local label=$1 difference=$2 uuid request_dir target_dir before_inode after_inode
    next_timer_uuid; uuid=$REPLY
    seed_timer_target "$uuid" ACTIVE 20 9 1 0 6 3 0 MAIN MESSAGE_ENTER 0 old-secondary
    request_dir="$TEST_TMP/rotation-$TIMER_CASE_ID"
    make_timer_request "$uuid" "$request_dir"
    ka_state_target_dir "$uuid"; target_dir=$REPLY
    case $difference in
        lf) printf '%s' main-one > "$request_dir/messages/001" ;;
        cr) printf 'main-one\r\n' > "$request_dir/messages/001" ;;
        count) rm -- "$request_dir/messages/002" ;;
        order)
            ka_write_scalar "$request_dir/messages/001" main-two
            ka_write_scalar "$request_dir/messages/002" main-one
            ;;
        content) ka_write_scalar "$request_dir/messages/001" changed-one ;;
    esac
    before_inode=$(stat -c '%i' "$target_dir/messages")
    ka_state_configure_target "$uuid" "$request_dir"
    after_inode=$(stat -c '%i' "$target_dir/messages")
    if [[ $difference == lf ]]; then
        assert_eq 1 "${KA_T_MAIN_INDEX[$uuid]}" "$label: index preserved"
        assert_eq MAIN "${KA_T_PENDING_SUBMIT[$uuid]}" "$label: owner preserved"
        assert_eq "$before_inode" "$after_inode" "$label: messages directory is not rewritten"
    else
        assert_eq 0 "${KA_T_MAIN_INDEX[$uuid]}" "$label: index resets"
        assert_eq STALE "${KA_T_PENDING_SUBMIT[$uuid]}" "$label: owed MAIN becomes STALE"
        assert_false "$label: changed messages directory is replaced" test "$before_inode" = "$after_inode"
    fi
    if [[ $difference == count ]]; then
        assert_eq 1 "$(ka_state_message_count "$uuid")" "$label: accepted count change is installed"
    fi
    if [[ $difference == cr ]]; then
        ka_state_target_dir "$uuid"; target_dir=$REPLY
        ka_request_read_scalar "$target_dir/messages/001" 2000
        assert_eq $'main-one\r' "$REPLY" "$label: CR remains message content"
    fi
}

# Main countdown caps apply for shorter intervals only; longer/equal intervals preserve
# the in-flight value and status for both ACTIVE and PAUSED targets.
for status in ACTIVE PAUSED; do
    for main_case in shorter longer equal; do
        next_timer_uuid; uuid=$REPLY
        seed_timer_target "$uuid" "$status" 20 18 1 1 8 6 0 0 MESSAGE_ENTER 0 unchanged-secondary
        request_dir="$TEST_TMP/main-$TIMER_CASE_ID"
        make_timer_request "$uuid" "$request_dir"
        case $main_case in
            shorter) ka_write_scalar "$request_dir/main_interval" 10; expected_main=10 ;;
            longer) ka_write_scalar "$request_dir/main_interval" 30; expected_main=18 ;;
            equal) ka_write_scalar "$request_dir/main_interval" 18; expected_main=18 ;;
        esac
        ka_state_configure_target "$uuid" "$request_dir"
        assert_eq "$expected_main" "${KA_T_MAIN_REMAIN[$uuid]}" "$status main $main_case interval preserves/caps countdown"
        assert_eq "$status" "${KA_T_STATUS[$uuid]}" "$status main $main_case interval preserves status"
        assert_eq 1 "${KA_T_MAIN_INDEX[$uuid]}" "$status main $main_case interval preserves rotation index"
    done
done

# One optional final LF is ignored; CR, count, order, and content remain meaningful.
run_rotation_case 'final LF only' lf
run_rotation_case 'CR content' cr
run_rotation_case 'message count' count
run_rotation_case 'message order' order
run_rotation_case 'message content' content

# Pending ownership is tied to the text that incurred the owed Enter. Main-only means a
# rotation change; interval-only changes are separately verified to preserve ownership.
for owner in 0 MAIN 1 SECONDARY_AUTO SECONDARY_MANUAL STALE; do
    for change in unchanged main secondary both; do
        next_timer_uuid; uuid=$REPLY
        seed_timer_target "$uuid" ACTIVE 20 14 1 1 8 5 0 "$owner" MESSAGE_ENTER 0 old-secondary
        request_dir="$TEST_TMP/owner-$TIMER_CASE_ID"
        make_timer_request "$uuid" "$request_dir"
        case $change in
            main|both) ka_write_scalar "$request_dir/messages/001" replacement-main ;;
        esac
        case $change in
            secondary|both) ka_write_scalar "$request_dir/secondary_message" replacement-secondary ;;
        esac
        ka_state_configure_target "$uuid" "$request_dir"
        expected_owner=$owner
        [[ $owner == 1 ]] && expected_owner=MAIN
        if [[ $owner != 0 && $owner != STALE && ( $change == main || $change == both ) ]]; then
            expected_owner=STALE
        elif [[ ( $owner == SECONDARY_AUTO || $owner == SECONDARY_MANUAL ) \
            && ( $change == secondary || $change == both ) ]]; then
            expected_owner=STALE
        fi
        assert_eq "$expected_owner" "${KA_T_PENDING_SUBMIT[$uuid]}" "pending $owner under $change change"
    done
done

next_timer_uuid; uuid=$REPLY
seed_timer_target "$uuid" ACTIVE 20 14 1 1 8 5 0 MAIN MESSAGE_ENTER 0 old-secondary
interval_request="$TEST_TMP/main-interval-owner"
make_timer_request "$uuid" "$interval_request"
ka_write_scalar "$interval_request/main_interval" 25
ka_state_configure_target "$uuid" "$interval_request"
assert_eq MAIN "${KA_T_PENDING_SUBMIT[$uuid]}" 'main interval-only change preserves the MAIN owner'

# Unchanged secondary settings retain both fields even after firing. Changed settings cap
# armed timers, re-arm fired/new prompts, and leave disabled prompts unarmed at their interval.
run_secondary_case 'enabled unchanged armed' 1 8 4 0 old 1 8 old 4 0
run_secondary_case 'enabled unchanged fired' 1 8 2 1 old 1 8 old 2 1
run_secondary_case 'enabled armed shorter interval' 1 8 6 0 old 1 3 old 3 0
run_secondary_case 'enabled armed longer interval' 1 8 4 0 old 1 12 old 4 0
run_secondary_case 'enabled armed message change' 1 8 4 0 old 1 8 new 4 0
run_secondary_case 'enabled fired changed interval re-arms' 1 8 2 1 old 1 12 old 12 0
run_secondary_case 'disabled to enabled arms' 0 8 3 0 old 1 12 old 12 0
run_secondary_case 'enabled to disabled clears one-shot' 1 8 3 1 old 0 12 old 12 0
run_secondary_case 'disabled unchanged preserves countdown' 0 8 3 1 old 0 8 old 3 1
run_secondary_case 'disabled changed interval resets state' 0 8 3 1 old 0 12 old 12 0
run_secondary_case 'disabled changed message resets state' 0 8 3 1 old 0 8 new 8 0

# A PAUSED ENTER_ONLY target keeps every scheduler field while notifications and delivery
# mode are edited; its messages and pending-submit owner remain associated with that state.
next_timer_uuid; uuid=$REPLY
seed_timer_target "$uuid" PAUSED 40 13 1 1 9 4 1 SECONDARY_MANUAL ENTER_ONLY 0 secondary-text
mode_request="$TEST_TMP/mode-notification-only"
make_timer_request "$uuid" "$mode_request"
ka_state_target_dir "$uuid"; mode_target_dir=$REPLY
mode_messages_inode=$(stat -c '%i' "$mode_target_dir/messages")
ka_write_scalar "$mode_request/notifications" 1
ka_write_scalar "$mode_request/delivery_mode" MESSAGE_ENTER
ka_state_configure_target "$uuid" "$mode_request"
assert_eq PAUSED "${KA_T_STATUS[$uuid]}" 'mode/notification-only CONFIGURE preserves PAUSED status'
assert_eq 40 "${KA_T_MAIN_INTERVAL[$uuid]}" 'mode/notification-only CONFIGURE preserves main interval'
assert_eq 13 "${KA_T_MAIN_REMAIN[$uuid]}" 'mode/notification-only CONFIGURE preserves main remaining'
assert_eq 1 "${KA_T_MAIN_INDEX[$uuid]}" 'mode/notification-only CONFIGURE preserves main index'
assert_eq 1 "${KA_T_SECONDARY_ENABLED[$uuid]}" 'mode/notification-only CONFIGURE preserves secondary enabled'
assert_eq 9 "${KA_T_SECONDARY_INTERVAL[$uuid]}" 'mode/notification-only CONFIGURE preserves secondary interval'
assert_eq 4 "${KA_T_SECONDARY_REMAIN[$uuid]}" 'mode/notification-only CONFIGURE preserves secondary remaining'
assert_eq 1 "${KA_T_SECONDARY_DONE[$uuid]}" 'mode/notification-only CONFIGURE preserves secondary done'
assert_eq secondary-text "${KA_T_SECONDARY_MESSAGE[$uuid]}" 'mode/notification-only CONFIGURE preserves secondary message'
assert_eq SECONDARY_MANUAL "${KA_T_PENDING_SUBMIT[$uuid]}" 'mode/notification-only CONFIGURE preserves pending owner'
assert_eq 1 "${KA_T_NOTIFY[$uuid]}" 'notification setting is saved independently'
assert_eq MESSAGE_ENTER "${KA_T_MODE[$uuid]}" 'delivery mode is saved independently'
assert_eq "$mode_messages_inode" "$(stat -c '%i' "$mode_target_dir/messages")" \
    'mode/notification-only CONFIGURE does not rewrite main messages'
assert_contains "$(ka_log_path "$uuid")" $'CONFIG\tconfiguration updated; countdowns kept\tOK' \
    'mode/notification-only CONFIGURE logs countdowns kept'

next_timer_uuid; uuid=$REPLY
seed_timer_target "$uuid" ACTIVE 20 9 0 0 8 4 0 0 MESSAGE_ENTER 0 old-secondary
arm_request="$TEST_TMP/secondary-arm-event"
make_timer_request "$uuid" "$arm_request"
ka_write_scalar "$arm_request/secondary_enabled" 1
ka_state_configure_target "$uuid" "$arm_request"
assert_contains "$(ka_log_path "$uuid")" $'CONFIG\tconfiguration updated; secondary prompt armed\tOK' \
    'CONFIG event reports a newly armed secondary prompt'

# Combined changes produce stable, ordered CONFIG event detail in the target event log.
next_timer_uuid; uuid=$REPLY
seed_timer_target "$uuid" ACTIVE 20 18 1 1 15 14 0 MAIN MESSAGE_ENTER 0 old-secondary
effect_request="$TEST_TMP/config-event-effect"
make_timer_request "$uuid" "$effect_request"
ka_write_scalar "$effect_request/main_interval" 10
ka_write_scalar "$effect_request/secondary_interval" 6
ka_write_scalar "$effect_request/messages/001" event-replacement
ka_state_configure_target "$uuid" "$effect_request"
assert_contains "$(ka_log_path "$uuid")" $'CONFIG\tconfiguration updated; main countdown capped at the new interval; secondary countdown capped at the new interval; rotation restarts at message 1\tOK' \
    'CONFIG event records ordered countdown-preservation effects'

# Rotation comparison preserves either value of the caller's nullglob setting.
next_timer_uuid; uuid=$REPLY
seed_timer_target "$uuid" ACTIVE 20 9 1 0 6 3 0 0 MESSAGE_ENTER 0 secondary
nullglob_request="$TEST_TMP/nullglob-request"
make_timer_request "$uuid" "$nullglob_request"
shopt -u nullglob
assert_true 'logical rotation equality works with nullglob disabled' ka_state_rotation_unchanged "$uuid" "$nullglob_request"
assert_false 'logical rotation comparison keeps nullglob disabled' shopt -q nullglob
shopt -s nullglob
assert_true 'logical rotation equality works with nullglob enabled' ka_state_rotation_unchanged "$uuid" "$nullglob_request"
assert_true 'logical rotation comparison keeps nullglob enabled' shopt -q nullglob
shopt -u nullglob

# CREATE uses absent=1 by default, honors explicit 0/1, and rejects every other value.
create_uuid='b1000000-0000-4000-8000-000000000001'
seed_discovered_session "$create_uuid"
create_request="$TEST_TMP/create-absent-policy"
ka_profile_copy_to_request "$create_request"
ka_write_scalar "$create_request/main_interval" 51
ka_state_create_target "$create_uuid" "$create_request"
assert_eq 51 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'CREATE absent policy updates the profile'
assert_eq 51 "${KA_T_MAIN_INTERVAL[$create_uuid]}" 'CREATE absent policy uses request settings'

create_uuid='b1000000-0000-4000-8000-000000000002'
seed_discovered_session "$create_uuid"
create_request="$TEST_TMP/create-zero-policy"
ka_profile_copy_to_request "$create_request"
ka_write_scalar "$create_request/main_interval" 52
ka_write_scalar "$create_request/profile_update" 0
ka_state_create_target "$create_uuid" "$create_request"
assert_eq 51 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'CREATE profile_update=0 leaves the profile alone'
assert_eq 52 "${KA_T_MAIN_INTERVAL[$create_uuid]}" 'CREATE profile_update=0 still uses request settings'

create_uuid='b1000000-0000-4000-8000-000000000003'
seed_discovered_session "$create_uuid"
create_request="$TEST_TMP/create-one-policy"
ka_profile_copy_to_request "$create_request"
ka_write_scalar "$create_request/main_interval" 53
ka_write_scalar "$create_request/profile_update" 1
ka_state_create_target "$create_uuid" "$create_request"
assert_eq 53 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'CREATE profile_update=1 updates the profile'

create_uuid='b1000000-0000-4000-8000-000000000004'
seed_discovered_session "$create_uuid"
create_request="$TEST_TMP/create-invalid-policy"
ka_profile_copy_to_request "$create_request"
ka_write_scalar "$create_request/main_interval" 54
ka_write_scalar "$create_request/profile_update" 2
assert_false 'CREATE refuses invalid profile_update' ka_state_create_target "$create_uuid" "$create_request"
assert_false 'invalid CREATE leaves no target behind' ka_state_has_target "$create_uuid"
assert_eq 53 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'invalid CREATE policy leaves profile unchanged'

# CONFIGURE retains absent=1, honors 0/1, and validates the policy before mutation.
next_timer_uuid; uuid=$REPLY
seed_timer_target "$uuid" ACTIVE 60 45 0 0 12 4 0 0 MESSAGE_ENTER 0 secondary
config_policy_request="$TEST_TMP/config-profile-absent"
make_timer_request "$uuid" "$config_policy_request"
rm -- "$config_policy_request/profile_update"
ka_write_scalar "$config_policy_request/main_interval" 50
ka_state_configure_target "$uuid" "$config_policy_request"
assert_eq 50 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'CONFIGURE absent policy updates the profile'

config_policy_request="$TEST_TMP/config-profile-zero"
make_timer_request "$uuid" "$config_policy_request"
ka_write_scalar "$config_policy_request/main_interval" 40
ka_write_scalar "$config_policy_request/profile_update" 0
ka_state_configure_target "$uuid" "$config_policy_request"
assert_eq 50 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'CONFIGURE profile_update=0 leaves profile alone'

config_policy_request="$TEST_TMP/config-profile-one"
make_timer_request "$uuid" "$config_policy_request"
ka_write_scalar "$config_policy_request/main_interval" 30
ka_write_scalar "$config_policy_request/profile_update" 1
ka_state_configure_target "$uuid" "$config_policy_request"
assert_eq 30 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'CONFIGURE profile_update=1 updates the profile'

config_policy_request="$TEST_TMP/config-profile-invalid"
make_timer_request "$uuid" "$config_policy_request"
ka_write_scalar "$config_policy_request/main_interval" 20
ka_write_scalar "$config_policy_request/profile_update" invalid
assert_false 'CONFIGURE refuses invalid profile_update' ka_state_configure_target "$uuid" "$config_policy_request"
assert_eq 30 "${KA_T_MAIN_INTERVAL[$uuid]}" 'invalid CONFIGURE policy leaves target unchanged'
assert_eq 30 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'invalid CONFIGURE policy leaves profile unchanged'

# A failed message-tree commit restores timers and ownership in memory and on disk, with one
# state-first checkpoint followed by one restore checkpoint.
rollback_uuid='c1000000-0000-4000-8000-000000000001'
seed_timer_target "$rollback_uuid" PAUSED 18 7 1 1 12 4 1 MAIN ENTER_ONLY 1 old-secondary
rollback_request="$TEST_TMP/failing-copy-request"
make_timer_request "$rollback_uuid" "$rollback_request"
ka_write_scalar "$rollback_request/main_interval" 30
ka_write_scalar "$rollback_request/secondary_enabled" 0
ka_write_scalar "$rollback_request/secondary_interval" 6
ka_write_scalar "$rollback_request/messages/001" changed-one
COPY_COMMIT_CALLS=0
# Role: Fail the changed-message commit once so CONFIGURE must restore its snapshot.
ka_commit_staged_dir() {
    local staged=$1 destination=$2
    COPY_COMMIT_CALLS=$((COPY_COMMIT_CALLS + 1))
    if ((COPY_COMMIT_CALLS == 1)); then return 77; fi
    rm -rf -- "$destination"
    mv -T -- "$staged" "$destination"
}
COUNT_STATE_SAVES=1
STATE_SAVE_COUNT=0
assert_false 'failed message-copy CONFIGURE returns failure' ka_state_configure_target "$rollback_uuid" "$rollback_request"
COUNT_STATE_SAVES=0
assert_eq 2 "$COPY_COMMIT_CALLS" 'failed message-copy CONFIGURE tries one apply and one restore copy'
assert_eq 2 "$STATE_SAVE_COUNT" 'message-copy rollback writes one apply and one restore checkpoint'
assert_eq PAUSED "${KA_T_STATUS[$rollback_uuid]}" 'message-copy rollback preserves PAUSED status'
assert_eq ENTER_ONLY "${KA_T_MODE[$rollback_uuid]}" 'message-copy rollback restores delivery mode'
assert_eq 1 "${KA_T_NOTIFY[$rollback_uuid]}" 'message-copy rollback restores notifications'
assert_eq 18 "${KA_T_MAIN_INTERVAL[$rollback_uuid]}" 'message-copy rollback restores main interval'
assert_eq 7 "${KA_T_MAIN_REMAIN[$rollback_uuid]}" 'message-copy rollback restores main remaining'
assert_eq 1 "${KA_T_MAIN_INDEX[$rollback_uuid]}" 'message-copy rollback restores rotation index'
assert_eq 1 "${KA_T_SECONDARY_ENABLED[$rollback_uuid]}" 'message-copy rollback restores secondary enabled'
assert_eq 12 "${KA_T_SECONDARY_INTERVAL[$rollback_uuid]}" 'message-copy rollback restores secondary interval'
assert_eq 4 "${KA_T_SECONDARY_REMAIN[$rollback_uuid]}" 'message-copy rollback restores secondary remaining'
assert_eq 1 "${KA_T_SECONDARY_DONE[$rollback_uuid]}" 'message-copy rollback restores fired secondary state'
assert_eq old-secondary "${KA_T_SECONDARY_MESSAGE[$rollback_uuid]}" 'message-copy rollback restores secondary message'
assert_eq MAIN "${KA_T_PENDING_SUBMIT[$rollback_uuid]}" 'message-copy rollback restores pending owner'
ka_state_init_arrays
assert_true 'message-copy rollback checkpoint reloads' ka_state_load_target_dir "$(target_dir "$rollback_uuid")"
assert_eq 18 "${KA_T_MAIN_INTERVAL[$rollback_uuid]}" 'reloaded copy rollback restores main interval'
assert_eq 7 "${KA_T_MAIN_REMAIN[$rollback_uuid]}" 'reloaded copy rollback restores main remaining'
assert_eq 12 "${KA_T_SECONDARY_INTERVAL[$rollback_uuid]}" 'reloaded copy rollback restores secondary interval'
assert_eq 4 "${KA_T_SECONDARY_REMAIN[$rollback_uuid]}" 'reloaded copy rollback restores secondary remaining'
assert_eq 1 "${KA_T_SECONDARY_DONE[$rollback_uuid]}" 'reloaded copy rollback restores secondary done'
assert_eq MAIN "${KA_T_PENDING_SUBMIT[$rollback_uuid]}" 'reloaded copy rollback restores pending owner'

# A profile-update failure after configuration commits restores the old text/checkpoint,
# including an owner that was changed to STALE by the attempted rotation edit.
profile_failure_uuid='c1000000-0000-4000-8000-000000000002'
seed_timer_target "$profile_failure_uuid" PAUSED 22 17 1 1 9 5 1 MAIN ENTER_ONLY 0 profile-old-secondary
profile_failure_request="$TEST_TMP/failing-profile-request"
make_timer_request "$profile_failure_uuid" "$profile_failure_request"
ka_write_scalar "$profile_failure_request/main_interval" 8
ka_write_scalar "$profile_failure_request/secondary_interval" 5
ka_write_scalar "$profile_failure_request/secondary_message" profile-new-secondary
ka_write_scalar "$profile_failure_request/messages/001" profile-new-main
ka_write_scalar "$profile_failure_request/profile_update" 1
profile_before=$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")
# Role: Inject a profile-commit failure after target configuration has been applied.
ka_profile_update_from_request() {
    ka_error 'injected profile update failure'
    return 1
}
COUNT_STATE_SAVES=1
STATE_SAVE_COUNT=0
assert_false 'profile-update failure makes CONFIGURE fail' ka_state_configure_target "$profile_failure_uuid" "$profile_failure_request"
COUNT_STATE_SAVES=0
assert_eq 2 "$STATE_SAVE_COUNT" 'profile rollback writes one apply and one restore checkpoint'
assert_eq "$profile_before" "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'failed profile update leaves profile intact'
assert_eq PAUSED "${KA_T_STATUS[$profile_failure_uuid]}" 'profile rollback restores PAUSED status'
assert_eq 22 "${KA_T_MAIN_INTERVAL[$profile_failure_uuid]}" 'profile rollback restores main interval'
assert_eq 17 "${KA_T_MAIN_REMAIN[$profile_failure_uuid]}" 'profile rollback restores main remaining'
assert_eq 1 "${KA_T_MAIN_INDEX[$profile_failure_uuid]}" 'profile rollback restores main index'
assert_eq 1 "${KA_T_SECONDARY_ENABLED[$profile_failure_uuid]}" 'profile rollback restores secondary enabled'
assert_eq 9 "${KA_T_SECONDARY_INTERVAL[$profile_failure_uuid]}" 'profile rollback restores secondary interval'
assert_eq 5 "${KA_T_SECONDARY_REMAIN[$profile_failure_uuid]}" 'profile rollback restores secondary remaining'
assert_eq 1 "${KA_T_SECONDARY_DONE[$profile_failure_uuid]}" 'profile rollback restores fired one-shot state'
assert_eq profile-old-secondary "${KA_T_SECONDARY_MESSAGE[$profile_failure_uuid]}" 'profile rollback restores secondary message'
assert_eq MAIN "${KA_T_PENDING_SUBMIT[$profile_failure_uuid]}" 'profile rollback restores owner from would-be STALE'
ka_state_init_arrays
assert_true 'profile-update rollback checkpoint reloads' ka_state_load_target_dir "$(target_dir "$profile_failure_uuid")"
assert_eq 22 "${KA_T_MAIN_INTERVAL[$profile_failure_uuid]}" 'reloaded profile rollback restores main interval'
assert_eq 17 "${KA_T_MAIN_REMAIN[$profile_failure_uuid]}" 'reloaded profile rollback restores main remaining'
assert_eq 9 "${KA_T_SECONDARY_INTERVAL[$profile_failure_uuid]}" 'reloaded profile rollback restores secondary interval'
assert_eq 5 "${KA_T_SECONDARY_REMAIN[$profile_failure_uuid]}" 'reloaded profile rollback restores secondary remaining'
assert_eq 1 "${KA_T_SECONDARY_DONE[$profile_failure_uuid]}" 'reloaded profile rollback restores secondary done'
assert_eq MAIN "${KA_T_PENDING_SUBMIT[$profile_failure_uuid]}" 'reloaded profile rollback restores pending owner'
assert_eq 0 "$(find "$KA_QUARANTINE_DIR" -mindepth 1 -maxdepth 1 -print | wc -l)" 'restored checkpoints are not quarantined'

test_finish
