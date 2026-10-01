#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
source "$TEST_ROOT/lib/icons.sh"
source "$TEST_ROOT/lib/tui/screen.sh"
source "$TEST_ROOT/lib/tui/tui.sh"
ka_state_init_arrays
ka_profile_init_defaults

# Role: Seed a complete Konsole target checkpoint without contacting a terminal backend.
seed_target() {
    local uuid=$1 secondary=$2 dir
    ka_state_register_uuid "$uuid"
    KA_T_BACKEND[$uuid]=konsole
    KA_T_TYPE[$uuid]=Claude
    KA_T_NAME[$uuid]="State hardening $uuid"
    KA_T_DIR[$uuid]='/work/state-hardening'
    KA_T_SERVICE[$uuid]='org.kde.konsole-100'
    KA_T_PATH[$uuid]='/Sessions/1'
    KA_T_TERM_PID[$uuid]=1
    KA_T_AI_PID[$uuid]=1
    KA_T_AI_START[$uuid]=1
    KA_T_STATUS[$uuid]=ACTIVE
    KA_T_MODE[$uuid]=MESSAGE_ENTER
    KA_T_NOTIFY[$uuid]=0
    KA_T_MAIN_INTERVAL[$uuid]=120
    KA_T_MAIN_REMAIN[$uuid]=60
    KA_T_MAIN_INDEX[$uuid]=0
    KA_T_SECONDARY_ENABLED[$uuid]=1
    KA_T_SECONDARY_INTERVAL[$uuid]=30
    KA_T_SECONDARY_REMAIN[$uuid]=20
    KA_T_SECONDARY_DONE[$uuid]=0
    KA_T_SECONDARY_MESSAGE[$uuid]=$secondary
    KA_T_LAST_SEEN[$uuid]=''
    KA_T_REASON[$uuid]=''
    ka_state_target_dir "$uuid"
    dir=$REPLY
    mkdir -p "$dir/messages"
    ka_write_scalar "$dir/messages/001" 'keep working'
    ka_state_save_target "$uuid"
}

# Role: Replace one checkpoint field while preserving the data-only TSV format.
replace_state_field() {
    local path=$1 wanted=$2 replacement=$3 key value extra
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

# Role: Report whether a directory has any direct children, including hidden entries.
directory_has_entries() {
    local directory=$1
    [[ -n $(find "$directory" -mindepth 1 -maxdepth 1 -print -quit) ]]
}

# Modern checkpoints use a per-save secondary-message companion reference. Both the
# loader and detail TUI must follow it, while old checkpoints still use the fixed name.
modern_uuid='71000000-0000-4000-8000-000000000010'
seed_target "$modern_uuid" 'versioned secondary prompt'
ka_state_target_dir "$modern_uuid"
modern_dir=$REPLY
modern_file=$(ka_state_read_field "$modern_uuid" secondary_message_file)
assert_true 'a saved checkpoint records a versioned secondary-message file' test -n "$modern_file"
assert_true 'the versioned secondary-message companion exists' test -f "$modern_dir/$modern_file"

ka_state_init_arrays
assert_true 'the loader follows a versioned secondary-message reference' ka_state_load_target_dir "$modern_dir"
assert_eq 'versioned secondary prompt' "${KA_T_SECONDARY_MESSAGE[$modern_uuid]}" \
    'versioned secondary-message content is restored'

KA_ICONS_ENABLED=0
KA_COLOR_ENABLED=0
KA_ASCII_MODE=1
ka_icons_init
ka_tui_style_init
KA_TUI_COLS=80
KA_TUI_LINES=30
KA_TUI_ACTIVE_VIEW=''
KA_TUI_RESIZED=0
ka_tui_load_target_fields "$modern_uuid"
assert_eq "$modern_file" "$KA_F_SEC_MESSAGE_FILE" \
    'detail field loading retains the versioned secondary-message reference'
modern_render="$TEST_TMP/modern-detail.render"
ka_tui_render_detail "$modern_uuid" >"$modern_render"
assert_contains "$modern_render" 'versioned secondary prompt' \
    'detail TUI renders the versioned secondary-message content'

# The client process never initializes daemon arrays. Configuration seeding must read the
# versioned companion named by state.tsv instead of expanding an undeclared associative map.
client_request="$TEST_TMP/client-request"
mkdir -p "$client_request"
unset KA_T_SECONDARY_MESSAGE
assert_true 'client configuration seeding works without daemon target arrays' \
    ka_state_copy_target_to_request "$modern_uuid" "$client_request"
assert_eq 'versioned secondary prompt' "$(ka_read_first_line "$client_request/secondary_message")" \
    'client configuration seeding copies the persisted secondary prompt'

# Remove only the new field and rename the companion to the pre-versioned filename.
legacy_state="$modern_dir/state.tsv"
grep -v $'^secondary_message_file\t' "$legacy_state" >"$legacy_state.legacy"
mv -- "$legacy_state.legacy" "$legacy_state"
mv -- "$modern_dir/$modern_file" "$modern_dir/secondary_message"
ka_state_init_arrays
assert_true 'legacy checkpoints without a message-file field still load' ka_state_load_target_dir "$modern_dir"
assert_eq 'versioned secondary prompt' "${KA_T_SECONDARY_MESSAGE[$modern_uuid]}" \
    'legacy secondary-message content is restored from the fixed companion'
ka_tui_load_target_fields "$modern_uuid"
assert_eq secondary_message "$KA_F_SEC_MESSAGE_FILE" \
    'detail field loading falls back to the legacy secondary-message filename'
legacy_render="$TEST_TMP/legacy-detail.render"
ka_tui_render_detail "$modern_uuid" >"$legacy_render"
assert_contains "$legacy_render" 'versioned secondary prompt' \
    'detail TUI renders the legacy fallback secondary-message content'

# Presence of a modern field matters: an explicit empty value is not the same as a
# missing field and must not silently select a default or legacy path.
empty_done_uuid='72000000-0000-4000-8000-000000000011'
ka_state_init_arrays
seed_target "$empty_done_uuid" 'empty done probe'
ka_state_target_dir "$empty_done_uuid"
empty_done_dir=$REPLY
replace_state_field "$empty_done_dir/state.tsv" secondary_done ''
assert_contains "$empty_done_dir/state.tsv" $'secondary_done\t' \
    'the empty secondary_done probe keeps the field explicitly present'
ka_state_init_arrays
assert_false 'an explicitly empty secondary_done field is rejected' \
    ka_state_load_target_dir "$empty_done_dir"
assert_eq 'secondary_done must be 0 or 1' "$KA_STATE_LOAD_ERROR" \
    'empty secondary_done rejection records its exact reason'

empty_file_uuid='73000000-0000-4000-8000-000000000012'
ka_state_init_arrays
seed_target "$empty_file_uuid" 'empty file probe'
ka_state_target_dir "$empty_file_uuid"
empty_file_dir=$REPLY
replace_state_field "$empty_file_dir/state.tsv" secondary_message_file ''
assert_contains "$empty_file_dir/state.tsv" $'secondary_message_file\t' \
    'the empty secondary_message_file probe keeps the field explicitly present'
ka_state_init_arrays
assert_false 'an explicitly empty secondary_message_file field is rejected' \
    ka_state_load_target_dir "$empty_file_dir"
assert_eq 'secondary message checkpoint reference is invalid' "$KA_STATE_LOAD_ERROR" \
    'empty secondary_message_file rejection records its exact reason'

# A scheduler checkpoint failure must stay retryable, and a failure while persisting an
# unavailable transition must not be replaced by a generic validation message.
scheduler_uuid='74000000-0000-4000-8000-000000000013'
ka_state_init_arrays
seed_target "$scheduler_uuid" 'scheduler persistence probe'
SAVE_RC=75
SAVE_CALLS=0
# Role: Inject a deterministic checkpoint failure/success and mirror dirty-marker clearing.
ka_state_save_target() {
    local uuid=$1
    ((SAVE_CALLS += 1))
    if ((SAVE_RC == 0)); then
        unset "KA_T_DIRTY[$uuid]"
    fi
    return "$SAVE_RC"
}
unset 'KA_T_DIRTY[$scheduler_uuid]'
rc=0
ka_scheduler_checkpoint "$scheduler_uuid" || rc=$?
assert_eq 75 "$rc" 'scheduler checkpoint returns the underlying save failure'
assert_eq 1 "${KA_T_DIRTY[$scheduler_uuid]:-0}" \
    'scheduler checkpoint leaves a dirty target for retry'
SAVE_CALLS=0
rc=0
ka_state_flush_dirty || rc=$?
assert_eq 1 "$rc" 'dirty flush reports a failed scheduler checkpoint'
assert_eq 1 "$SAVE_CALLS" 'dirty flush retries the failed scheduler checkpoint'
assert_eq 1 "${KA_T_DIRTY[$scheduler_uuid]:-0}" \
    'a failed dirty flush keeps the target dirty'
SAVE_RC=0
SAVE_CALLS=0
rc=0
ka_state_flush_dirty || rc=$?
assert_eq 0 "$rc" 'dirty flush reports recovery after persistence becomes available'
assert_eq 1 "$SAVE_CALLS" 'dirty flush retries after persistence becomes available'
assert_eq '' "${KA_T_DIRTY[$scheduler_uuid]-}" \
    'a successful dirty flush clears the retry marker'

# Role: Return a completed identity mismatch while unavailable-state persistence fails.
ka_konsole_validate_target() { return 10; }
SAVE_RC=77
KA_LAST_ERROR=''
KA_SCHEDULER_VALIDATION_REASON=''
rc=0
ka_scheduler_send_main "$scheduler_uuid" MANUAL || rc=$?
assert_eq 3 "$rc" 'send reports failure when unavailable-state persistence fails'
assert_eq 'could not save unavailable target state' "$KA_LAST_ERROR" \
    'send preserves the specific unavailable-state persistence error'
assert_eq 'could not save unavailable target state' "$KA_SCHEDULER_VALIDATION_REASON" \
    'scheduler validation retains the specific unavailable-state persistence error'
assert_eq ACTIVE "${KA_T_STATUS[$scheduler_uuid]}" \
    'failed unavailable-state persistence rolls the in-memory status back'
source "$TEST_ROOT/lib/state.sh"
source "$TEST_ROOT/lib/konsole.sh"

# Configuration requests must never follow a symlink for the secondary prompt.
symlink_uuid='75000000-0000-4000-8000-000000000014'
symlink_request="$TEST_TMP/symlink-request"
ka_profile_copy_to_request "$symlink_request"
external_message="$TEST_TMP/external-secondary"
ka_write_scalar "$external_message" 'external message must remain outside the request'
rm -f -- "$symlink_request/secondary_message"
ln -s -- "$external_message" "$symlink_request/secondary_message"
ka_state_init_arrays
KA_D_UUIDS=("$symlink_uuid")
KA_D_TYPE[$symlink_uuid]=Claude
KA_D_NAME[$symlink_uuid]='Symlink request'
KA_D_DIR[$symlink_uuid]='/work/state-hardening'
KA_D_SERVICE[$symlink_uuid]='org.kde.konsole-100'
KA_D_PATH[$symlink_uuid]='/Sessions/1'
KA_D_TERM_PID[$symlink_uuid]=1
KA_D_AI_PID[$symlink_uuid]=1
KA_D_AI_START[$symlink_uuid]=1
ka_error_reset
assert_false 'CREATE rejects a symlinked secondary-message request' \
    ka_state_create_target "$symlink_uuid" "$symlink_request"
assert_eq 'secondary message is missing or not a regular file' "$KA_LAST_ERROR" \
    'symlinked secondary-message rejection records its exact reason'
assert_false 'rejected symlink request creates no target directory' \
    test -e "$(target_dir "$symlink_uuid")"
assert_eq 'external message must remain outside the request' "$(cat -- "$external_message")" \
    'symlink rejection does not modify the external message'

# A safe UUID still must not follow a pre-planted target-directory symlink during CREATE.
target_link_uuid='76000000-0000-4000-8000-000000000015'
target_link_request="$TEST_TMP/target-link-request"
target_link_external="$TEST_TMP/target-link-external"
ka_profile_copy_to_request "$target_link_request"
mkdir -p "$target_link_external"
ka_write_scalar "$target_link_external/sentinel" 'outside target state'
ka_state_target_dir "$target_link_uuid"
target_link_path=$REPLY
ln -s -- "$target_link_external" "$target_link_path"
ka_state_init_arrays
KA_D_UUIDS=("$target_link_uuid")
KA_D_TYPE[$target_link_uuid]=Claude
KA_D_NAME[$target_link_uuid]='Target symlink request'
KA_D_DIR[$target_link_uuid]='/work/state-hardening'
KA_D_SERVICE[$target_link_uuid]='org.kde.konsole-100'
KA_D_PATH[$target_link_uuid]='/Sessions/1'
KA_D_TERM_PID[$target_link_uuid]=1
KA_D_AI_PID[$target_link_uuid]=1
KA_D_AI_START[$target_link_uuid]=1
ka_error_reset
assert_false 'CREATE rejects a pre-planted target-directory symlink' \
    ka_state_create_target "$target_link_uuid" "$target_link_request"
assert_eq 'could not create target runtime state' "$KA_LAST_ERROR" \
    'target-directory symlink rejection is explained'
assert_eq 'outside target state' "$(ka_read_first_line "$target_link_external/sentinel")" \
    'target-directory symlink rejection preserves external contents'
assert_false 'target-directory symlink rejection writes no external checkpoint' \
    test -e "$target_link_external/state.tsv"
rm -f -- "$target_link_path"

# Startup recovery must restore the sole rollback tree before stale staging cleanup.
recovery_uuid='77000000-0000-4000-8000-000000000016'
ka_state_init_arrays
seed_target "$recovery_uuid" 'recovery secondary prompt'
ka_state_target_dir "$recovery_uuid"
recovery_dir=$REPLY
mv -T -- "$recovery_dir/messages" "$recovery_dir/messages.trash.interrupted"
assert_true 'startup recovery restores an interrupted message rotation' \
    ka_state_recover_target_messages
assert_file "$recovery_dir/messages/001" \
    'startup recovery retains the only copy of the main message'

# An index destination that is already a directory must fail instead of nesting the
# temporary index file inside it and falsely reporting a successful publication.
index_destination="$TEST_TMP/index-destination"
mkdir -p "$index_destination"
KA_INDEX_FILE="$index_destination"
KA_T_UUIDS=()
KA_D_UUIDS=()
rc=0
ka_state_publish_index 2>"$TEST_TMP/index-publish.err" || rc=$?
assert_eq 1 "$rc" 'index publication rejects a directory destination'
assert_true 'index destination remains a directory after rejection' test -d "$index_destination"
assert_false 'failed index publication does not nest a temporary file' \
    directory_has_entries "$index_destination"

# Two same-process saves may overlap. Unique staging directories must keep each payload
# isolated; a fixed messages.staged.$$ path lets the nested save replace the outer payload.
copy_target="$TEST_TMP/copy-target"
request_a="$TEST_TMP/request-a"
request_b="$TEST_TMP/request-b"
mkdir -p "$copy_target/messages" "$request_a/messages" "$request_b/messages"
ka_write_scalar "$copy_target/messages/001" old
ka_write_scalar "$request_a/messages/001" payload-a
ka_write_scalar "$request_b/messages/001" payload-b
stale_stage="$copy_target/messages.staged.$$"
mkdir -p "$stale_stage"
ka_write_scalar "$stale_stage/001" stale-payload
STAGED_PAYLOADS=()
COMMIT_CALLS=0
# Role: Re-enter the copy path during its first commit to model overlapping saves.
ka_commit_staged_dir() {
    local staged=$1 destination=$2 payload
    ((COMMIT_CALLS += 1))
    if ((COMMIT_CALLS == 1)); then
        ka_state_copy_request_messages "$request_b" "$copy_target"
    fi
    payload=$(cat -- "$staged/001")
    STAGED_PAYLOADS+=("$payload")
}
ka_state_copy_request_messages "$request_a" "$copy_target"
assert_eq 2 "$COMMIT_CALLS" 'overlapping saves each reach an isolated commit stage'
assert_eq payload-b "${STAGED_PAYLOADS[0]}" \
    'nested save keeps its own payload in its staging directory'
assert_eq payload-a "${STAGED_PAYLOADS[1]}" \
    'outer save retains its payload after the nested save'

# The test has overridden only library functions; no live runtime or user state was used.
test_finish
