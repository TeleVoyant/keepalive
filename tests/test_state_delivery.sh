#!/usr/bin/env bash
# Durable state/configuration, pending-submit ownership, and delivery metadata regressions.
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
ka_state_init_arrays

# Role: Seed one complete target checkpoint without contacting a terminal backend.
seed_target() {
    local uuid=$1
    local main_index=${2:-0}
    local pending_owner_value=${3:-0}
    local secondary_enabled=${4:-1}
    local secondary_message=${5:-secondary-nudge}
    local target_dir
    ka_state_register_uuid "$uuid"
    KA_T_BACKEND[$uuid]=konsole
    KA_T_TYPE[$uuid]=Claude
    KA_T_NAME[$uuid]="State delivery $uuid"
    KA_T_DIR[$uuid]=/work/state-delivery
    KA_T_SERVICE[$uuid]=org.kde.konsole-100
    KA_T_PATH[$uuid]=/Sessions/1
    KA_T_TERM_PID[$uuid]=1
    KA_T_AI_PID[$uuid]=1
    KA_T_AI_START[$uuid]=1
    KA_T_STATUS[$uuid]=ACTIVE
    KA_T_MODE[$uuid]=MESSAGE_ENTER
    KA_T_NOTIFY[$uuid]=0
    KA_T_MAIN_INTERVAL[$uuid]=10
    KA_T_MAIN_REMAIN[$uuid]=10
    KA_T_MAIN_INDEX[$uuid]=$main_index
    KA_T_SECONDARY_ENABLED[$uuid]=$secondary_enabled
    KA_T_SECONDARY_INTERVAL[$uuid]=5
    KA_T_SECONDARY_REMAIN[$uuid]=5
    KA_T_SECONDARY_DONE[$uuid]=0
    KA_T_SECONDARY_MESSAGE[$uuid]=$secondary_message
    KA_T_LAST_SEEN[$uuid]=''
    KA_T_REASON[$uuid]=''
    KA_T_PENDING_SUBMIT[$uuid]=$pending_owner_value
    ka_state_target_dir "$uuid"
    target_dir=$REPLY
    mkdir -p -- "$target_dir/messages"
    ka_write_scalar "$target_dir/messages/001" main-one
    ka_write_scalar "$target_dir/messages/002" main-two
    ka_state_save_target "$uuid"
}

# Role: Build a private, valid configuration request with an optional replacement rotation.
make_request() {
    local request_dir=$1
    local first=${2:-new-one}
    local second=${3:-new-two}
    mkdir -p -- "$request_dir/messages"
    chmod 700 "$request_dir" "$request_dir/messages"
    ka_write_scalar "$request_dir/delivery_mode" MESSAGE_ENTER
    ka_write_scalar "$request_dir/notifications" 0
    ka_write_scalar "$request_dir/main_interval" 20
    ka_write_scalar "$request_dir/secondary_enabled" 0
    ka_write_scalar "$request_dir/secondary_interval" 7
    ka_write_scalar "$request_dir/secondary_message" replacement-secondary
    ka_write_scalar "$request_dir/messages/001" "$first"
    ka_write_scalar "$request_dir/messages/002" "$second"
}

# Role: Replace one scalar row in a checkpoint while retaining its data-only TSV format.
replace_state_field() {
    local path=$1
    local wanted=$2
    local replacement=$3
    local key value extra
    {
        while IFS=$'\t' read -r key value extra; do
            if [[ $key == "$wanted" ]]; then
                printf '%s\t%s\n' "$key" "$replacement"
            else
                printf '%s\t%s\n' "$key" "$value"
            fi
        done <"$path"
    } | ka_atomic_write "$path"
}

# Role: Reset a target's scheduler-only state before an isolated delivery scenario.
reset_delivery_target() {
    local uuid=$1
    local pending_owner_value=${2:-0}
    KA_T_STATUS[$uuid]=ACTIVE
    KA_T_MODE[$uuid]=MESSAGE_ENTER
    KA_T_MAIN_REMAIN[$uuid]=10
    KA_T_MAIN_INDEX[$uuid]=0
    KA_T_SECONDARY_REMAIN[$uuid]=5
    KA_T_SECONDARY_DONE[$uuid]=0
    KA_T_PENDING_SUBMIT[$uuid]=$pending_owner_value
    KA_T_LAST_DELIVERY_TIME[$uuid]=''
    KA_T_LAST_DELIVERY_EVENT[$uuid]=''
    KA_T_LAST_DELIVERY_RESULT[$uuid]=''
    KA_T_LAST_DELIVERY_DETAIL[$uuid]=''
}

# Role: Make scheduler validation deterministic without touching a terminal backend.
ka_scheduler_validate_before_send() {
    return 0
}

# Role: Capture transport calls and return the scenario-selected result code.
ka_transport_deliver() {
    local uuid=$1
    local mode=$2
    local message=${3-}
    local submit_only=${4:-0}
    DELIVERIES+=("$mode|$message|$submit_only")
    return "$DELIVERY_RC"
}

# Role: Suppress notifications while asserting scheduler state transitions.
ka_notify_sent() {
    :
}

# Role: Suppress failed-delivery notifications while asserting scheduler state transitions.
ka_notify_send_failed() {
    :
}

# The CONFIGURE state-first commit must survive a process dying before messages/ is swapped.
crash_uuid='81000000-0000-4000-8000-000000000081'
seed_target "$crash_uuid" 1 MAIN 0
crash_request="$TEST_TMP/crash-request"
make_request "$crash_request" replacement-one replacement-two
rm -f -- "$crash_request/messages/002"
# Role: Model a daemon death immediately before the message-tree swap.
ka_state_copy_request_messages() {
    exit 0
}
(ka_state_apply_request_configuration "$crash_uuid" "$crash_request")
source "$TEST_ROOT/lib/state.sh"
ka_state_init_arrays
ka_state_target_dir "$crash_uuid"
crash_target_dir=$REPLY
assert_true 'CONFIGURE crash checkpoint reloads successfully' ka_state_load_all_targets
assert_eq STALE "${KA_T_PENDING_SUBMIT[$crash_uuid]}" \
    'CONFIGURE crash checkpoint marks the old owed submit STALE'
assert_eq 0 "${KA_T_MAIN_INDEX[$crash_uuid]}" \
    'CONFIGURE crash checkpoint resets the replacement rotation index'
assert_eq 0 "$(find "$KA_QUARANTINE_DIR" -mindepth 1 -maxdepth 1 -print | wc -l)" \
    'CONFIGURE crash checkpoint is not quarantined'
DELIVERIES=()
DELIVERY_RC=0
assert_true 'STALE MAIN retry succeeds with its owed Enter and current line' ka_scheduler_send_main "$crash_uuid" AUTO
assert_eq 'MESSAGE_ENTER||1' "${DELIVERIES[0]-}" \
    'STALE MAIN retry submits only Enter before the current message'
assert_eq 'MESSAGE_ENTER|main-one|0' "${DELIVERIES[1]-}" \
    'STALE MAIN retry then sends rotation line 1'
assert_eq 1 "${KA_T_MAIN_INDEX[$crash_uuid]}" \
    'STALE submit itself does not advance before the current line advances once'

# A failed message-copy commit must restore the previous rotation and pending owner.
rollback_uuid='82000000-0000-4000-8000-000000000082'
seed_target "$rollback_uuid" 1 MAIN 0
ka_state_target_dir "$rollback_uuid"
rollback_target_dir=$REPLY
ka_write_scalar "$rollback_target_dir/messages/001" old-one
ka_write_scalar "$rollback_target_dir/messages/002" old-two
KA_T_MAIN_INDEX[$rollback_uuid]=1
KA_T_PENDING_SUBMIT[$rollback_uuid]=MAIN
# shellcheck disable=SC2218
ka_state_save_target "$rollback_uuid"
rollback_request="$TEST_TMP/rollback-request"
make_request "$rollback_request" replacement-one replacement-two
COMMIT_CALLS=0
# Role: Fail the first rotation commit, then allow the rollback copy to commit.
ka_commit_staged_dir() {
    local staged=$1
    local destination=$2
    COMMIT_CALLS=$((COMMIT_CALLS + 1))
    if ((COMMIT_CALLS == 1)); then
        return 77
    fi
    rm -rf -- "$destination"
    mv -T -- "$staged" "$destination"
}
assert_false 'CONFIGURE reports a failed message-copy commit' \
    ka_state_configure_target "$rollback_uuid" "$rollback_request"
assert_eq 2 "$COMMIT_CALLS" 'CONFIGURE invokes the rollback message copy after failure'
assert_eq old-one "$(ka_state_message_at "$rollback_uuid" 0)" \
    'rollback restores old message line 1'
assert_eq old-two "$(ka_state_message_at "$rollback_uuid" 1)" \
    'rollback restores old message line 2'
assert_eq 1 "${KA_T_MAIN_INDEX[$rollback_uuid]}" \
    'rollback restores the old rotation index'
assert_eq MAIN "${KA_T_PENDING_SUBMIT[$rollback_uuid]}" \
    'rollback restores the old pending-submit owner'
ka_state_init_arrays
assert_true 'rollback checkpoint reloads after the failed copy' \
    ka_state_load_target_dir "$(target_dir "$rollback_uuid")"
assert_eq MAIN "${KA_T_PENDING_SUBMIT[$rollback_uuid]}" \
    'rollback persists the old pending-submit owner'
assert_eq 1 "${KA_T_MAIN_INDEX[$rollback_uuid]}" \
    'rollback persists the old rotation index'
source "$TEST_ROOT/lib/common.sh"

# Pending-submit owners are event-specific: same-kind events submit once, cross-kind events
# press the owed Enter before delivering their own text, and STALE never advances rotation.
matrix_uuid='83000000-0000-4000-8000-000000000083'
seed_target "$matrix_uuid" 0 0 1 nudge
DELIVERY_RC=0
DELIVERIES=()
reset_delivery_target "$matrix_uuid" SECONDARY_MANUAL
assert_true 'automatic SECONDARY completes a manual secondary owner once' \
    ka_scheduler_send_secondary "$matrix_uuid" AUTO
assert_eq 1 "${#DELIVERIES[@]}" 'same-kind automatic SECONDARY submits exactly once'
assert_eq 'MESSAGE_ENTER||1' "${DELIVERIES[0]}" \
    'same-kind automatic SECONDARY sends only Enter'
assert_eq 0 "${KA_T_PENDING_SUBMIT[$matrix_uuid]}" \
    'same-kind automatic SECONDARY clears the owner'
assert_eq 1 "${KA_T_SECONDARY_DONE[$matrix_uuid]}" \
    'same-kind automatic SECONDARY marks the one-shot done'

DELIVERIES=()
reset_delivery_target "$matrix_uuid" SECONDARY_AUTO
assert_true 'manual SECONDARY completes an automatic secondary owner once' \
    ka_scheduler_send_secondary "$matrix_uuid" MANUAL
assert_eq 1 "${#DELIVERIES[@]}" 'same-kind manual SECONDARY submits exactly once'
assert_eq 'MESSAGE_ENTER||1' "${DELIVERIES[0]}" \
    'same-kind manual SECONDARY sends only Enter'
assert_eq 0 "${KA_T_PENDING_SUBMIT[$matrix_uuid]}" \
    'manual same-kind SECONDARY clears the owner'
assert_eq 1 "${KA_T_SECONDARY_DONE[$matrix_uuid]}" \
    'manual same-kind SECONDARY preserves the completed one-shot'

DELIVERIES=()
reset_delivery_target "$matrix_uuid" MAIN
assert_true 'cross-kind SECONDARY completes MAIN before its own text' \
    ka_scheduler_send_secondary "$matrix_uuid" MANUAL
assert_eq 2 "${#DELIVERIES[@]}" 'cross-kind SECONDARY performs two ordered deliveries'
assert_eq 'MESSAGE_ENTER||1' "${DELIVERIES[0]}" \
    'cross-kind SECONDARY submits the owed MAIN Enter first'
assert_eq 'MESSAGE_ENTER|nudge|0' "${DELIVERIES[1]}" \
    'cross-kind SECONDARY then sends its own text'
assert_eq 0 "${KA_T_PENDING_SUBMIT[$matrix_uuid]}" \
    'cross-kind SECONDARY clears the completed MAIN owner'

DELIVERIES=()
reset_delivery_target "$matrix_uuid" SECONDARY_MANUAL
assert_true 'cross-kind MAIN completes SECONDARY before its own text' \
    ka_scheduler_send_main "$matrix_uuid" AUTO
assert_eq 2 "${#DELIVERIES[@]}" 'cross-kind MAIN performs two ordered deliveries'
assert_eq 'MESSAGE_ENTER||1' "${DELIVERIES[0]}" \
    'cross-kind MAIN submits the owed SECONDARY Enter first'
assert_eq 'MESSAGE_ENTER|main-one|0' "${DELIVERIES[1]}" \
    'cross-kind MAIN then sends its own text'
assert_eq 1 "${KA_T_MAIN_INDEX[$matrix_uuid]}" \
    'cross-kind MAIN advances only its own rotation'

reset_delivery_target "$matrix_uuid" STALE
assert_true 'STALE completion transition succeeds' \
    ka_scheduler_complete_pending_owner "$matrix_uuid" STALE 2
assert_eq 0 "${KA_T_MAIN_INDEX[$matrix_uuid]}" \
    'STALE completion transition never advances the rotation'
DELIVERIES=()
reset_delivery_target "$matrix_uuid" STALE
assert_true 'STALE MAIN retry submits Enter before its current line' \
    ka_scheduler_send_main "$matrix_uuid" AUTO
assert_eq 'MESSAGE_ENTER||1' "${DELIVERIES[0]}" 'STALE retry sends only Enter first'
assert_eq 'MESSAGE_ENTER|main-one|0' "${DELIVERIES[1]}" 'STALE retry then sends the first line'
assert_eq 1 "${KA_T_MAIN_INDEX[$matrix_uuid]}" \
    'only the current MAIN line advances the rotation after STALE'

# Delivery metadata is written at existing scheduler checkpoints, not in an extra save.
delivery_uuid='84000000-0000-4000-8000-000000000084'
seed_target "$delivery_uuid" 0 0 1 nudge
SAVE_CALLS=0
# Role: Count scheduler checkpoint calls without changing the in-memory state.
ka_state_save_target() {
    local uuid=$1
    SAVE_CALLS=$((SAVE_CALLS + 1))
    return 0
}

reset_delivery_target "$delivery_uuid" 0
DELIVERIES=()
DELIVERY_RC=0
SAVE_CALLS=0
assert_true 'MAIN success records delivery metadata' ka_scheduler_send_main "$delivery_uuid" MANUAL
assert_eq 2 "$SAVE_CALLS" 'MAIN success uses its two existing checkpoints only'
assert_eq MAIN "${KA_T_LAST_DELIVERY_EVENT[$delivery_uuid]}" 'MAIN success records event kind'
assert_eq 'SENT · manual' "${KA_T_LAST_DELIVERY_RESULT[$delivery_uuid]}" 'MAIN success records result'
assert_eq main-one "${KA_T_LAST_DELIVERY_DETAIL[$delivery_uuid]}" 'MAIN success records delivered detail'
assert_true 'MAIN success records a delivery time' test -n "${KA_T_LAST_DELIVERY_TIME[$delivery_uuid]}"

reset_delivery_target "$delivery_uuid" 0
DELIVERIES=()
DELIVERY_RC=1
SAVE_CALLS=0
assert_false 'MAIN failure records delivery metadata' ka_scheduler_send_main "$delivery_uuid" MANUAL
assert_eq 2 "$SAVE_CALLS" 'MAIN failure uses its two existing checkpoints only'
assert_eq MAIN "${KA_T_LAST_DELIVERY_EVENT[$delivery_uuid]}" 'MAIN failure records event kind'
assert_eq 'FAILED · manual' "${KA_T_LAST_DELIVERY_RESULT[$delivery_uuid]}" 'MAIN failure records result'
assert_eq main-one "${KA_T_LAST_DELIVERY_DETAIL[$delivery_uuid]}" 'MAIN failure records delivered detail'

reset_delivery_target "$delivery_uuid" 0
DELIVERIES=()
DELIVERY_RC=0
SAVE_CALLS=0
assert_true 'SECONDARY success records delivery metadata' ka_scheduler_send_secondary "$delivery_uuid" MANUAL
assert_eq 2 "$SAVE_CALLS" 'SECONDARY success uses its two existing checkpoints only'
assert_eq SECONDARY "${KA_T_LAST_DELIVERY_EVENT[$delivery_uuid]}" 'SECONDARY success records event kind'
assert_eq 'SENT · manual' "${KA_T_LAST_DELIVERY_RESULT[$delivery_uuid]}" 'SECONDARY success records result'
assert_eq nudge "${KA_T_LAST_DELIVERY_DETAIL[$delivery_uuid]}" 'SECONDARY success records delivered detail'

reset_delivery_target "$delivery_uuid" 0
DELIVERIES=()
DELIVERY_RC=1
SAVE_CALLS=0
assert_false 'SECONDARY failure records delivery metadata' ka_scheduler_send_secondary "$delivery_uuid" MANUAL
assert_eq 2 "$SAVE_CALLS" 'SECONDARY failure uses its two existing checkpoints only'
assert_eq SECONDARY "${KA_T_LAST_DELIVERY_EVENT[$delivery_uuid]}" 'SECONDARY failure records event kind'
assert_eq 'FAILED · manual' "${KA_T_LAST_DELIVERY_RESULT[$delivery_uuid]}" 'SECONDARY failure records result'
assert_eq nudge "${KA_T_LAST_DELIVERY_DETAIL[$delivery_uuid]}" 'SECONDARY failure records delivered detail'

reset_delivery_target "$delivery_uuid" 0
DELIVERIES=()
DELIVERY_RC=0
SAVE_CALLS=0
assert_true 'ENTER success records delivery metadata' ka_scheduler_send_enter_once "$delivery_uuid" MANUAL
assert_eq 1 "$SAVE_CALLS" 'ENTER success uses its one existing checkpoint only'
assert_eq ENTER "${KA_T_LAST_DELIVERY_EVENT[$delivery_uuid]}" 'ENTER success records event kind'
assert_eq 'SENT · manual' "${KA_T_LAST_DELIVERY_RESULT[$delivery_uuid]}" 'ENTER success records result'
assert_eq '[ENTER] one-shot' "${KA_T_LAST_DELIVERY_DETAIL[$delivery_uuid]}" 'ENTER success records delivered detail'

reset_delivery_target "$delivery_uuid" 0
DELIVERIES=()
DELIVERY_RC=1
SAVE_CALLS=0
assert_false 'ENTER failure records delivery metadata' ka_scheduler_send_enter_once "$delivery_uuid" MANUAL
assert_eq 1 "$SAVE_CALLS" 'ENTER failure uses its one existing checkpoint only'
assert_eq ENTER "${KA_T_LAST_DELIVERY_EVENT[$delivery_uuid]}" 'ENTER failure records event kind'
assert_eq 'FAILED · manual' "${KA_T_LAST_DELIVERY_RESULT[$delivery_uuid]}" 'ENTER failure records result'
assert_eq '[ENTER] one-shot' "${KA_T_LAST_DELIVERY_DETAIL[$delivery_uuid]}" 'ENTER failure records delivered detail'

source "$TEST_ROOT/lib/state.sh"
DELIVERY_RC=0
assert_true 'last-delivery metadata can be checkpointed' ka_state_save_target "$delivery_uuid"
delivery_state_dir=$(target_dir "$delivery_uuid")
ka_state_init_arrays
assert_true 'last-delivery metadata survives reload' ka_state_load_target_dir "$delivery_state_dir"
assert_eq ENTER "${KA_T_LAST_DELIVERY_EVENT[$delivery_uuid]}" 'reloaded event kind is preserved'
assert_eq 'FAILED · manual' "${KA_T_LAST_DELIVERY_RESULT[$delivery_uuid]}" 'reloaded result is preserved'
assert_eq '[ENTER] one-shot' "${KA_T_LAST_DELIVERY_DETAIL[$delivery_uuid]}" 'reloaded detail is preserved'
assert_true 'reloaded delivery time is preserved' test -n "${KA_T_LAST_DELIVERY_TIME[$delivery_uuid]}"

# Legacy checkpoints without the appended metadata fields load as never-delivered.
absent_uuid='85000000-0000-4000-8000-000000000085'
seed_target "$absent_uuid" 0 0 0
absent_state_dir=$(target_dir "$absent_uuid")
grep -vE '^(last_delivery_time|last_delivery_event|last_delivery_result|last_delivery_detail)' \
    "$absent_state_dir/state.tsv" >"$absent_state_dir/state.tsv.old"
mv -- "$absent_state_dir/state.tsv.old" "$absent_state_dir/state.tsv"
ka_state_init_arrays
assert_true 'checkpoint without delivery fields still loads' ka_state_load_target_dir "$absent_state_dir"
assert_eq '' "${KA_T_LAST_DELIVERY_TIME[$absent_uuid]-}" 'absent delivery time means never delivered'
assert_eq '' "${KA_T_LAST_DELIVERY_EVENT[$absent_uuid]-}" 'absent delivery event means never delivered'
assert_eq '' "${KA_T_LAST_DELIVERY_RESULT[$absent_uuid]-}" 'absent delivery result means never delivered'
assert_eq '' "${KA_T_LAST_DELIVERY_DETAIL[$absent_uuid]-}" 'absent delivery detail means never delivered'

# A malformed display-only event is dropped while the healthy target remains active.
malformed_uuid='86000000-0000-4000-8000-000000000086'
seed_target "$malformed_uuid" 0 0 0
malformed_state_dir=$(target_dir "$malformed_uuid")
replace_state_field "$malformed_state_dir/state.tsv" last_delivery_event NOT_AN_EVENT
replace_state_field "$malformed_state_dir/state.tsv" last_delivery_time invalid-time
replace_state_field "$malformed_state_dir/state.tsv" last_delivery_result invalid-result
replace_state_field "$malformed_state_dir/state.tsv" last_delivery_detail invalid-detail
ka_state_init_arrays
assert_true 'malformed delivery event does not quarantine a target' ka_state_load_all_targets
assert_eq '' "${KA_T_LAST_DELIVERY_EVENT[$malformed_uuid]-}" 'malformed event is discarded'
assert_eq '' "${KA_T_LAST_DELIVERY_TIME[$malformed_uuid]-}" 'malformed event clears its time'
assert_eq '' "${KA_T_LAST_DELIVERY_RESULT[$malformed_uuid]-}" 'malformed event clears its result'
assert_eq '' "${KA_T_LAST_DELIVERY_DETAIL[$malformed_uuid]-}" 'malformed event clears its detail'
assert_true 'malformed delivery target remains on disk' test -d "$(target_dir "$malformed_uuid")"
assert_eq 0 "$(find "$KA_QUARANTINE_DIR" -mindepth 1 -maxdepth 1 -print | wc -l)" \
    'malformed delivery target creates no quarantine record'

# Valid display metadata is bounded on load rather than making a target unrecoverable.
bounded_uuid='87000000-0000-4000-8000-000000000087'
seed_target "$bounded_uuid" 0 0 0
bounded_state_dir=$(target_dir "$bounded_uuid")
long_time=$(printf '%*s' 80 '')
long_time=${long_time// /t}
long_result=$(printf '%*s' 150 '')
long_result=${long_result// /r}
long_detail=$(printf '%*s' 300 '')
long_detail=${long_detail// /d}
replace_state_field "$bounded_state_dir/state.tsv" last_delivery_event MAIN
replace_state_field "$bounded_state_dir/state.tsv" last_delivery_time "$long_time"
replace_state_field "$bounded_state_dir/state.tsv" last_delivery_result "$long_result"
replace_state_field "$bounded_state_dir/state.tsv" last_delivery_detail "$long_detail"
ka_state_init_arrays
assert_true 'oversized delivery metadata does not quarantine a target' ka_state_load_all_targets
assert_eq 64 "${#KA_T_LAST_DELIVERY_TIME[$bounded_uuid]}" 'delivery time is truncated to 64 characters'
assert_eq 128 "${#KA_T_LAST_DELIVERY_RESULT[$bounded_uuid]}" 'delivery result is truncated to 128 characters'
assert_eq 256 "${#KA_T_LAST_DELIVERY_DETAIL[$bounded_uuid]}" 'delivery detail is capped at 256 characters'
assert_true 'bounded delivery target remains on disk' test -d "$(target_dir "$bounded_uuid")"

# Secondary companion reads are bounded and tolerate exactly one optional final newline.
secondary_uuid='88000000-0000-4000-8000-000000000088'
seed_target "$secondary_uuid" 0 0 1
secondary_state_dir=$(target_dir "$secondary_uuid")
secondary_file=$(ka_state_read_field "$secondary_uuid" secondary_message_file)
long_secondary=$(printf '%*s' 2001 '')
long_secondary=${long_secondary// /s}
printf '%s' "$long_secondary" >"$secondary_state_dir/$secondary_file"
ka_state_init_arrays
assert_false 'enabled oversized secondary companion is rejected' \
    ka_state_load_target_dir "$secondary_state_dir"
assert_eq 'enabled secondary_message must be one logical line of at most 2000 characters' \
    "$KA_STATE_LOAD_ERROR" 'enabled oversized companion reports its bounded-load reason'
replace_state_field "$secondary_state_dir/state.tsv" secondary_enabled 0
ka_state_init_arrays
assert_true 'disabled oversized secondary companion still loads' \
    ka_state_load_target_dir "$secondary_state_dir"
assert_eq '' "${KA_T_SECONDARY_MESSAGE[$secondary_uuid]}" \
    'disabled oversized companion is discarded rather than retained'
printf 'line-one\nline-two\n' >"$secondary_state_dir/$secondary_file"
ka_state_init_arrays
assert_true 'disabled multiline secondary companion still loads' \
    ka_state_load_target_dir "$secondary_state_dir"
assert_eq '' "${KA_T_SECONDARY_MESSAGE[$secondary_uuid]}" \
    'disabled multiline companion is discarded rather than retained'
replace_state_field "$secondary_state_dir/state.tsv" secondary_enabled 1
printf '%s' normal-secondary >"$secondary_state_dir/$secondary_file"
ka_state_init_arrays
assert_true 'normal secondary companion without newline loads' \
    ka_state_load_target_dir "$secondary_state_dir"
assert_eq normal-secondary "${KA_T_SECONDARY_MESSAGE[$secondary_uuid]}" \
    'secondary companion without newline is accepted'
ka_write_scalar "$secondary_state_dir/$secondary_file" normal-secondary
ka_state_init_arrays
assert_true 'normal secondary companion with trailing newline loads' \
    ka_state_load_target_dir "$secondary_state_dir"
assert_eq normal-secondary "${KA_T_SECONDARY_MESSAGE[$secondary_uuid]}" \
    'secondary companion with one trailing newline is accepted'

# The pre-enum flag value 1 loads as MAIN, matching the in-memory canonicalization that
# runs before every save, rather than quarantining the target.
legacy_uuid='89000000-0000-4000-8000-000000000089'
seed_target "$legacy_uuid" 0 0 0
legacy_state_dir=$(target_dir "$legacy_uuid")
replace_state_field "$legacy_state_dir/state.tsv" pending_submit 1
ka_state_init_arrays
assert_true 'legacy persisted pending-submit value 1 loads' \
    ka_state_load_target_dir "$legacy_state_dir"
assert_eq MAIN "${KA_T_PENDING_SUBMIT[$legacy_uuid]-}" \
    'legacy persisted pending-submit value 1 loads as MAIN'
replace_state_field "$legacy_state_dir/state.tsv" pending_submit BOGUS
ka_state_init_arrays
assert_false 'an unknown persisted pending-submit value is still rejected' \
    ka_state_load_target_dir "$legacy_state_dir"

test_finish
