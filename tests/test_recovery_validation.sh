#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
ka_state_init_arrays

# Role: Seed one structurally valid runtime target checkpoint for recovery tests.
seed_checkpoint() {
    local uuid=$1 dir
    ka_state_register_uuid "$uuid"
    KA_T_TYPE[$uuid]='Claude'; KA_T_NAME[$uuid]="Recovery-$uuid"; KA_T_DIR[$uuid]='/work/recovery'
    KA_T_SERVICE[$uuid]='org.kde.konsole-100'; KA_T_PATH[$uuid]='/Sessions/1'; KA_T_TERM_PID[$uuid]=$$
    KA_T_AI_PID[$uuid]=$$; KA_T_AI_START[$uuid]=$(ka_proc_starttime $$); KA_T_STATUS[$uuid]=ACTIVE
    KA_T_MODE[$uuid]=MESSAGE_ENTER; KA_T_NOTIFY[$uuid]=0; KA_T_MAIN_INTERVAL[$uuid]=120; KA_T_MAIN_REMAIN[$uuid]=60
    KA_T_MAIN_INDEX[$uuid]=0; KA_T_SECONDARY_ENABLED[$uuid]=1; KA_T_SECONDARY_INTERVAL[$uuid]=30
    KA_T_SECONDARY_REMAIN[$uuid]=20; KA_T_SECONDARY_MESSAGE[$uuid]='nudge'; KA_T_LAST_SEEN[$uuid]=''; KA_T_REASON[$uuid]=''
    dir=$(ka_state_target_dir "$uuid")
    mkdir -p "$dir/messages"
    ka_write_scalar "$dir/messages/001" ping
    ka_state_save_target "$uuid"
}

# Role: Atomically replace one key in a data-only target state checkpoint.
replace_checkpoint_field() {
    local path=$1 wanted=$2 replacement=$3 key value rest
    {
        while IFS=$'\t' read -r key value rest; do
            if [[ $key == "$wanted" ]]; then
                printf '%s\t%s\n' "$key" "$replacement"
            else
                printf '%s\t%s\n' "$key" "$value"
            fi
        done <"$path"
    } | ka_atomic_write "$path"
}

# Role: Locate the quarantine reason file associated with one original target basename.
quarantine_reason_path() {
    local base=$1 match
    shopt -s nullglob
    for match in "$KA_QUARANTINE_DIR/$base".*; do
        [[ -d $match ]] || continue
        printf '%s/quarantine_reason' "$match"
        return 0
    done
    return 1
}

valid_uuid='10000000-0000-4000-8000-000000000001'
gap_uuid='20000000-0000-4000-8000-000000000002'
start_uuid='30000000-0000-4000-8000-000000000003'
range_uuid='40000000-0000-4000-8000-000000000004'
required_uuid='50000000-0000-4000-8000-000000000005'
identity_uuid='60000000-0000-4000-8000-000000000006'
replacement_uuid='69999999-9999-4999-8999-999999999999'
message_link_uuid='70000000-0000-4000-8000-000000000007'

for uuid in "$valid_uuid" "$gap_uuid" "$start_uuid" "$range_uuid" "$required_uuid" "$identity_uuid" "$message_link_uuid"; do
    seed_checkpoint "$uuid"
done

mv -- "$(ka_state_target_dir "$gap_uuid")/messages/001" "$(ka_state_target_dir "$gap_uuid")/messages/002"
replace_checkpoint_field "$(ka_state_target_dir "$start_uuid")/state.tsv" ai_start invalid
replace_checkpoint_field "$(ka_state_target_dir "$range_uuid")/state.tsv" main_remaining 121
rm -f -- "$(ka_state_target_dir "$required_uuid")/secondary_message"
replace_checkpoint_field "$(ka_state_target_dir "$identity_uuid")/state.tsv" uuid "$replacement_uuid"
external_message="$TEST_TMP/external-message"
ka_write_scalar "$external_message" 'external message must not be followed'
rm -f -- "$(ka_state_target_dir "$message_link_uuid")/messages/001"
ln -s -- "$external_message" "$(ka_state_target_dir "$message_link_uuid")/messages/001"
external_record="$TEST_TMP/external-record"
mkdir -p "$external_record"
ln -s -- "$external_record" "$KA_TARGETS_DIR/unsafe-link"
ka_log_event "$start_uuid" TEST 'preserve quarantine evidence' EXPECTED

# Model a fresh daemon process loading only on-disk runtime records.
ka_state_init_arrays
ka_state_load_all_targets

assert_true 'valid checkpoint is restored' ka_state_has_target "$valid_uuid"
assert_eq 60 "${KA_T_MAIN_REMAIN[$valid_uuid]}" 'valid checkpoint preserves main remaining time'
assert_false 'gapped message checkpoint is not loaded' ka_state_has_target "$gap_uuid"
assert_false 'invalid ai_start checkpoint is not loaded' ka_state_has_target "$start_uuid"
assert_false 'out-of-range timer checkpoint is not loaded' ka_state_has_target "$range_uuid"
assert_false 'missing required file checkpoint is not loaded' ka_state_has_target "$required_uuid"
assert_false 'uuid/directory mismatch checkpoint is not loaded' ka_state_has_target "$replacement_uuid"
assert_false 'symlinked main-message checkpoint is not loaded' ka_state_has_target "$message_link_uuid"

quarantine_count=$(find "$KA_QUARANTINE_DIR" -mindepth 1 -maxdepth 1 -type d | wc -l)
assert_eq 7 "$quarantine_count" 'every malformed checkpoint is moved into quarantine'

gap_reason=$(quarantine_reason_path "$gap_uuid")
start_reason=$(quarantine_reason_path "$start_uuid")
range_reason=$(quarantine_reason_path "$range_uuid")
required_reason=$(quarantine_reason_path "$required_uuid")
identity_reason=$(quarantine_reason_path "$identity_uuid")
message_link_reason=$(quarantine_reason_path "$message_link_uuid")
entry_link_reason=$(quarantine_reason_path unsafe-link)
assert_contains "$gap_reason" 'main message rotation is not contiguous' 'quarantine records message-rotation reason'
assert_contains "$start_reason" 'ai_start must be positive' 'quarantine records process-start reason'
assert_contains "$range_reason" 'main_remaining exceeds main_interval' 'quarantine records scalar-range reason'
assert_contains "$required_reason" 'secondary_message is missing' 'quarantine records missing-file reason'
assert_contains "$identity_reason" 'target directory does not match stored uuid' 'quarantine records identity-path reason'
assert_contains "$message_link_reason" 'main message rotation is not contiguous' 'quarantine rejects symlinked main messages'
assert_contains "$entry_link_reason" 'target entry is not a regular directory' 'quarantine rejects symlinked target entries'
assert_file "${start_reason%/*}/events.log" 'quarantine preserves the malformed target event log'
assert_true 'quarantine does not follow the rejected target symlink' test -d "$external_record"

test_finish
