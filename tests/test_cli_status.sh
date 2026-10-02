#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
export TERM=dumb
export NO_COLOR=1
source_core
source "$TEST_ROOT/lib/icons.sh"
source "$TEST_ROOT/lib/tui/screen.sh"
source "$TEST_ROOT/lib/tui/tui.sh"
KA_ICONS_ENABLED=0
KA_COLOR_ENABLED=0
KA_ASCII_MODE=1
ka_icons_init
ka_tui_style_init

# Role: Write an isolated service and index snapshot for the read-only status command.
write_status_snapshot() {
    local pid=$1 state=$2 version=$3 pid_start=${4-auto} now row
    printf -v now '%(%s)T' -1
    # The daemon records its own start time; "auto" mirrors that for the given PID, and
    # "none" writes the legacy (pre-pid_start) snapshot shape.
    if [[ $pid_start == auto ]]; then
        pid_start=''
        ka_proc_starttime_set "$pid" && pid_start=$REPLY
    fi
    printf 'state\t%s\npid\t%s\nversion\t%s\nupdated_epoch\t%s\n' \
        "$state" "$pid" "$version" "$now" >"$KA_SERVICE_STATE_FILE"
    [[ $pid_start == none ]] || printf 'pid_start\t%s\n' "$pid_start" >>"$KA_SERVICE_STATE_FILE"
    row='status-uuid\tClaude\tStatus target\t/work/status\tACTIVE\t120\t300\t1\t60\t90\tMESSAGE_ENTER\t1\t2026-10-01 12:00:00\t\tkonsole\t2026-10-01 12:02:00\t2026-10-01 12:01:00\t2026-10-01 12:00:00\tMAIN\tOK\tstatus message'
    printf '%b\n' "$row" >"$KA_INDEX_FILE"
}

# Role: Snapshot runtime entries and content while deliberately excluding the heartbeat file.
runtime_snapshot_without_presence() {
    local base=$1 path rel hash
    while IFS= read -r -d '' path; do
        rel=${path#"$base"/}
        [[ $rel == clients.seen ]] && continue
        if [[ -f $path && ! -L $path ]]; then
            hash=$(sha256sum -- "$path")
            printf 'file\t%s\t%s\n' "$rel" "${hash%% *}"
        elif [[ -p $path ]]; then
            printf 'fifo\t%s\n' "$rel"
        elif [[ -d $path && ! -L $path ]]; then
            printf 'dir\t%s\n' "$rel"
        else
            printf 'other\t%s\n' "$rel"
        fi
    done < <(find "$base" -mindepth 1 -print0 | sort -z)
}

# Role: Run status --json while retaining its exit status for an assertion.
run_status_json() {
    local output=$1 error=$2
    "$TEST_ROOT/keepalive" status --json >"$output" 2>"$error"
}

# Role: Build a temporary entrypoint copy whose functions can be driven without dispatching its CLI.
load_cli_functions() {
    local entry_dir=$TEST_TMP/cli-entry
    rm -rf -- "$entry_dir"
    mkdir -p "$entry_dir"
    cp -- "$TEST_ROOT/keepalive" "$entry_dir/keepalive"
    sed -i '$d' "$entry_dir/keepalive"
    ln -s "$TEST_ROOT/lib" "$entry_dir/lib"
    # shellcheck disable=SC1090
    source "$entry_dir/keepalive"
}

# Role: Create a minimal target checkpoint and index row for in-process detail rendering.
write_detail_fixture() {
    local uuid=$1 target_dir state_file secondary_file
    uuid=$1
    ka_state_target_dir "$uuid"
    target_dir=$REPLY
    state_file="$target_dir/state.tsv"
    secondary_file='secondary_message.123.456'
    mkdir -p "$target_dir/messages"
    chmod 700 "$target_dir" "$target_dir/messages"
    printf 'backend\tkonsole\ntype\tClaude\nname\tOld Target\ndirectory\t/work/old\nstatus\tACTIVE\nmode\tMESSAGE_ENTER\nnotifications\t0\nmain_remaining\t90\nmain_interval\t300\nmain_index\t0\nsecondary_enabled\t1\nsecondary_remaining\t45\nsecondary_interval\t60\nsecondary_done\t0\nsecondary_message_file\t%s\nlast_seen\t2026-10-01 12:00:00\nreason\t\nlast_delivery_time\t2026-10-01 11:59:00\nlast_delivery_event\tMAIN\nlast_delivery_result\tOK\nlast_delivery_detail\told detail\n' \
        "$secondary_file" >"$state_file"
    printf 'old secondary\n' >"$target_dir/$secondary_file"
    printf 'old main\n' >"$target_dir/messages/001"
    mkdir -p "$KA_LOGS_DIR"
    printf '12:00:00\tMAIN\told detail\tOK\n' >"$KA_LOGS_DIR/$uuid.log"
    printf '%s\tClaude\tOld Target\t/work/old\tACTIVE\t90\t300\t1\t45\t60\tMESSAGE_ENTER\t0\t2026-10-01 12:00:00\t\tkonsole\t2026-10-01 12:02:00\t2026-10-01 12:01:00\t2026-10-01 11:59:00\tMAIN\tOK\told detail\n' \
        "$uuid" >"$KA_INDEX_FILE"
    ka_tui_load_index
}

# Read-only status: an online live-pid snapshot is valid JSON and writes nothing at all - not
# even the client-presence stamp, which would keep the daemon on its fast discovery cadence.
status_pid=$$
write_status_snapshot "$status_pid" online 1.1.0
fake_bin="$TEST_TMP/fake-bin"
mkdir -p "$fake_bin"
cat >"$fake_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"${FAKE_SYSTEMCTL_LOG:?}"
exit 99
EOF
chmod 700 "$fake_bin/systemctl"
export FAKE_SYSTEMCTL_LOG="$TEST_TMP/systemctl.calls"
export PATH="$fake_bin:$PATH"
rm -f -- "$KA_CLIENT_PRESENCE_FILE"
status_before=$(runtime_snapshot_without_presence "$KA_RUNTIME_DIR")
status_output="$TEST_TMP/status-online.json"
status_error="$TEST_TMP/status-online.err"
status_rc=0
run_status_json "$status_output" "$status_error" || status_rc=$?
assert_eq 0 "$status_rc" 'status --json accepts an isolated online live-pid snapshot'
status_after=$(runtime_snapshot_without_presence "$KA_RUNTIME_DIR")
assert_eq "$status_before" "$status_after" 'status --json does not rewrite service/index snapshots or create other files'
assert_false 'status --json does not stamp client presence' test -e "$KA_CLIENT_PRESENCE_FILE"
assert_false 'status --json does not create or write a control FIFO' test -e "$KA_CONTROL_FIFO"
assert_false 'status --json never invokes systemctl' test -e "$FAKE_SYSTEMCTL_LOG"
if command -v jq >/dev/null 2>&1; then
    assert_true 'status --json output is valid JSON' jq empty "$status_output"
    assert_eq true "$(jq -r '.service.online' "$status_output")" 'online status reflects the live fixture pid'
    assert_eq "$status_pid" "$(jq -r '.service.pid' "$status_output")" 'online status publishes the fixture pid'
    assert_eq 1.1.0 "$(jq -r '.service.version' "$status_output")" 'online status publishes the daemon version'
    # A live PID is not enough: a later process reusing it must not read as the daemon.
    write_status_snapshot "$status_pid" online 1.1.0 1
    run_status_json "$status_output" "$status_error" || true
    assert_eq false "$(jq -r '.service.online' "$status_output")" \
        'a live pid whose start time differs from the recorded one is not online'
    write_status_snapshot "$status_pid" online 1.1.0 none
    run_status_json "$status_output" "$status_error" || true
    assert_eq false "$(jq -r '.service.online' "$status_output")" \
        'a legacy snapshot naming a non-daemon process is not online'
    write_status_snapshot "$status_pid" online 1.1.0
    run_status_json "$status_output" "$status_error" || true
    assert_true 'online status includes a numeric service age' jq -e '.service.status_age_seconds | type == "number"' "$status_output"
    assert_true 'status targets retain legacy and appended JSON keys' jq -e '.targets[0] | has("uuid") and has("backend") and has("type") and has("name") and has("directory") and has("status") and has("main_remaining") and has("main_interval") and has("secondary_enabled") and has("secondary_remaining") and has("secondary_interval") and has("mode") and has("notifications") and has("last_seen") and has("reason") and has("next_main_at") and has("next_secondary_at") and has("last_delivery")' "$status_output"
    assert_eq 2026-10-01\ 12:02:00 "$(jq -r '.targets[0].next_main_at' "$status_output")" 'status target carries next_main_at'
    assert_eq 2026-10-01\ 12:01:00 "$(jq -r '.targets[0].next_secondary_at' "$status_output")" 'status target carries next_secondary_at'
    assert_eq MAIN "$(jq -r '.targets[0].last_delivery.event' "$status_output")" 'status target carries last_delivery event'
    assert_eq OK "$(jq -r '.targets[0].last_delivery.result' "$status_output")" 'status target carries last_delivery result'
else
    test_skip 'status JSON parser check' 'jq is not installed'
fi

# A dead published pid is offline but remains useful diagnostic data in status JSON.
write_status_snapshot 2147483646 online 1.1.0
status_output="$TEST_TMP/status-offline.json"
status_error="$TEST_TMP/status-offline.err"
status_rc=0
run_status_json "$status_output" "$status_error" || status_rc=$?
assert_eq 0 "$status_rc" 'status --json treats a dead published pid as an offline service'
if command -v jq >/dev/null 2>&1; then
    assert_eq false "$(jq -r '.service.online' "$status_output")" 'offline status reports online false'
    assert_eq 2147483646 "$(jq -r '.service.pid' "$status_output")" 'offline status retains the known dead pid'
fi
rm -f -- "$KA_SERVICE_STATE_FILE"
status_rc=0
run_status_json "$status_output" "$status_error" || status_rc=$?
assert_eq 0 "$status_rc" 'status --json remains successful without service.state'
if command -v jq >/dev/null 2>&1; then
    assert_eq false "$(jq -r '.service.online' "$status_output")" 'missing service.state reports online false'
    assert_eq null "$(jq -r '.service.pid' "$status_output")" 'missing service.state reports a null pid'
fi

# Runtime hardening: status rejects an unsafe runtime child before touching external data.
external_runtime="$TEST_TMP/external-runtime"
mkdir -p "$external_runtime"
rm -rf -- "$KA_RUNTIME_DIR"
ln -s "$external_runtime" "$KA_RUNTIME_DIR"
status_rc=0
run_status_json "$TEST_TMP/status-symlink.json" "$TEST_TMP/status-symlink.err" || status_rc=$?
assert_eq 1 "$status_rc" 'status --json rejects a symlinked runtime directory'
assert_contains "$TEST_TMP/status-symlink.err" 'runtime directory is unsafe' 'symlinked runtime failure explains the refusal'
assert_false 'symlinked runtime refusal does not create an external heartbeat' test -e "$external_runtime/clients.seen"
rm -f -- "$KA_RUNTIME_DIR"
mkdir -p "$KA_RUNTIME_DIR"
chmod 700 "$KA_RUNTIME_DIR"
if ((EUID == 0)) && id -u nobody >/dev/null 2>&1; then
    chown "nobody:$(id -g nobody)" "$KA_RUNTIME_DIR"
    status_rc=0
    run_status_json "$TEST_TMP/status-foreign.json" "$TEST_TMP/status-foreign.err" || status_rc=$?
    assert_eq 1 "$status_rc" 'status --json rejects a foreign-owned runtime directory'
    chown "$(id -u):$(id -g)" "$KA_RUNTIME_DIR"
else
    test_skip 'foreign-owned status runtime is rejected' 'requires root and nobody'
fi

# Index compatibility: legacy 15-column rows leave all appended values empty.
legacy_uuid='legacy-uuid'
printf '%b\n' 'legacy-uuid\tClaude\tLegacy\t/work/legacy\tACTIVE\t10\t20\t1\t5\t6\tMESSAGE_ENTER\t0\tlast\treason\tkonsole' >"$KA_INDEX_FILE"
ka_tui_load_index
assert_eq 1 "${#KA_R_UUID[@]}" '15-column index row loads into the new reader'
assert_eq konsole "${KA_R_BACKEND[0]}" 'legacy index row defaults its backend to Konsole'
assert_eq '' "${KA_R_NEXT_MAIN[0]}" 'legacy index row has no next-main field'
assert_eq '' "${KA_R_NEXT_SECONDARY[0]}" 'legacy index row has no next-secondary field'
assert_eq '' "${KA_R_LAST_DELIVERY_TIME[0]}" 'legacy index row has no last-delivery time'
assert_eq '' "${KA_R_LAST_DELIVERY_EVENT[0]}" 'legacy index row has no last-delivery event'

# Appended 21-column rows populate every new detail field without shifting empty legacy columns.
new_uuid='new-index-uuid'
printf '%b\n' 'new-index-uuid\tCodex\tNew\t/work/new\tACTIVE\t7\t14\t1\t3\t6\tENTER_ONLY\t1\tseen\twhy\torca\t2026-10-01 12:02:00\t2026-10-01 12:03:00\t2026-10-01 12:01:00\tSECONDARY\tOK\tnudge sent' >"$KA_INDEX_FILE"
ka_tui_load_index
assert_eq orca "${KA_R_BACKEND[0]}" '21-column index row populates backend'
assert_eq '2026-10-01 12:02:00' "${KA_R_NEXT_MAIN[0]}" '21-column index row populates next-main'
assert_eq '2026-10-01 12:03:00' "${KA_R_NEXT_SECONDARY[0]}" '21-column index row populates next-secondary'
assert_eq '2026-10-01 12:01:00' "${KA_R_LAST_DELIVERY_TIME[0]}" '21-column index row populates delivery time'
assert_eq SECONDARY "${KA_R_LAST_DELIVERY_EVENT[0]}" '21-column index row populates delivery event'
assert_eq OK "${KA_R_LAST_DELIVERY_RESULT[0]}" '21-column index row populates delivery result'
assert_eq 'nudge sent' "${KA_R_LAST_DELIVERY_DETAIL[0]}" '21-column index row populates delivery detail'

# Detail cache: actions invalidate durable data, and state mtime changes trigger the next reload.
detail_uuid='detail-cache-uuid'
write_detail_fixture "$detail_uuid"
KA_TUI_COLS=80
KA_TUI_LINES=30
KA_TUI_ACTIVE_VIEW=''
KA_TUI_RESIZED=0
detail_output="$TEST_TMP/detail-first.out"
detail_rc=0
ka_tui_render_detail "$detail_uuid" >"$detail_output" || detail_rc=$?
assert_eq 0 "$detail_rc" 'detail renderer loads its initial durable cache'
assert_eq 'old secondary' "$KA_TUI_DETAIL_SECONDARY" 'detail cache stores the secondary prompt'
assert_eq 'old main' "${KA_TUI_DETAIL_MESSAGES[0]}" 'detail cache stores message rotation text'
printf 'new secondary\n' >"$(target_dir "$detail_uuid")/secondary_message.123.456"
printf 'new main\n' >"$(target_dir "$detail_uuid")/messages/001"
ka_tui_detail_cache_invalidate
detail_rc=0
ka_tui_render_detail "$detail_uuid" >"$TEST_TMP/detail-action.out" || detail_rc=$?
assert_eq 0 "$detail_rc" 'detail renderer refreshes after an action invalidates its cache'
assert_eq 'new secondary' "$KA_TUI_DETAIL_SECONDARY" 'action invalidation reloads the secondary prompt'
assert_eq 'new main' "${KA_TUI_DETAIL_MESSAGES[0]}" 'action invalidation reloads message rotation text'
state_file="$(target_dir "$detail_uuid")/state.tsv"
sed 's/^name\tOld Target$/name\tChanged Target/' "$state_file" >"$TEST_TMP/changed-state"
mv -- "$TEST_TMP/changed-state" "$state_file"
assert_true 'detail cache notices a newer state.tsv mtime' ka_tui_detail_cache_needs_reload "$detail_uuid"
detail_rc=0
ka_tui_render_detail "$detail_uuid" >"$TEST_TMP/detail-mtime.out" || detail_rc=$?
assert_eq 0 "$detail_rc" 'detail renderer completes after a state mtime change'
assert_eq 'Changed Target' "$KA_F_NAME" 'state mtime reloads changed checkpoint fields'

# Public list/list --json: each path performs exactly one REFRESH and no preliminary PING.
load_cli_functions
# Role: Replace IPC with a durable request counter so list calls can be counted across command substitutions.
ka_ipc_call() {
    printf '%s\t%s\n' "$1" "${2-}" >>"$KA_IPC_CALL_LOG"
    if [[ ${KA_IPC_FAIL:-0} == 1 ]]; then
        printf 'ERROR\tservice unavailable'
        return 1
    fi
    printf 'OK\trefresh complete'
}

KA_IPC_CALL_LOG="$TEST_TMP/ipc-calls"
export KA_IPC_CALL_LOG
KA_IPC_FAIL=0
printf '%b\n' 'list-uuid\tClaude\tListed\t/work/list\tAVAILABLE\t0\t0\t0\t0\t0\t\t0\t\t\tkonsole\t\t\t\t\t\t' >"$XDG_RUNTIME_DIR/keepalive/index.tsv"
: >"$KA_IPC_CALL_LOG"
list_rc=0
ka_cli_main list >"$TEST_TMP/list.out" 2>"$TEST_TMP/list.err" || list_rc=$?
assert_eq 0 "$list_rc" 'plain list succeeds with one stubbed refresh'
assert_eq 1 "$(wc -l <"$KA_IPC_CALL_LOG")" 'plain list issues exactly one IPC request'
assert_eq REFRESH "$(awk -F '\t' 'NR == 1 { print $1 }' "$KA_IPC_CALL_LOG")" 'plain list request is REFRESH, not PING'
: >"$KA_IPC_CALL_LOG"
list_rc=0
ka_cli_main list --json >"$TEST_TMP/list.json" 2>"$TEST_TMP/list-json.err" || list_rc=$?
assert_eq 0 "$list_rc" 'list --json succeeds with one stubbed refresh'
assert_eq 1 "$(wc -l <"$KA_IPC_CALL_LOG")" 'list --json issues exactly one IPC request'
assert_eq REFRESH "$(awk -F '\t' 'NR == 1 { print $1 }' "$KA_IPC_CALL_LOG")" 'list --json request is REFRESH, not PING'
if command -v jq >/dev/null 2>&1; then
    assert_true 'list --json output is valid JSON' jq empty "$TEST_TMP/list.json"
fi
KA_IPC_FAIL=1
: >"$KA_IPC_CALL_LOG"
list_rc=0
ka_cli_main list --json >"$TEST_TMP/list-unavailable.json" 2>"$TEST_TMP/list-unavailable.err" || list_rc=$?
assert_eq 1 "$list_rc" 'list --json propagates unavailable service failure'
assert_contains "$TEST_TMP/list-unavailable.err" 'service unavailable' 'unavailable list reports the service error'
assert_eq 1 "$(wc -l <"$KA_IPC_CALL_LOG")" 'unavailable list still sends only one IPC request'

# Release notes extraction is literal, rejects empty sections, and validates semantic versions.
notes_fixture="$TEST_TMP/notes.md"
cat >"$notes_fixture" <<'EOF'
# Changelog

## [1x1x0] - bogus
WRONG NOTES

## [1.1.0] - 2026-10-01
RIGHT NOTES

## [1.0.0] - old
OLD NOTES
EOF
notes_rc=0
notes_output=$("$TEST_ROOT/scripts/release-notes.sh" 1.1.0 "$notes_fixture") || notes_rc=$?
assert_eq 0 "$notes_rc" 'release-notes extracts the exact version section'
assert_eq 'RIGHT NOTES' "$notes_output" 'release-notes excludes a regex-like bogus heading'
assert_false 'release-notes does not emit the bogus section body' grep -Fq -- 'WRONG NOTES' <<<"$notes_output"
empty_notes="$TEST_TMP/empty-notes.md"
cat >"$empty_notes" <<'EOF'
# Changelog
## [2.0.0] - 2026-10-01

## [1.0.0] - old
OLD
EOF
notes_rc=0
"$TEST_ROOT/scripts/release-notes.sh" 2.0.0 "$empty_notes" >"$TEST_TMP/empty-notes.out" 2>"$TEST_TMP/empty-notes.err" || notes_rc=$?
assert_eq 1 "$notes_rc" 'release-notes rejects an empty release section'
notes_rc=0
"$TEST_ROOT/scripts/release-notes.sh" 1x1x0 "$notes_fixture" >"$TEST_TMP/malformed-version.out" 2>"$TEST_TMP/malformed-version.err" || notes_rc=$?
assert_eq 1 "$notes_rc" 'release-notes rejects a malformed version argument'

# Version bumping is repeatable and creates one dated heading for a release.
bump_root="$TEST_TMP/bump-repo"
mkdir -p "$bump_root"
cp -a "$TEST_ROOT/." "$bump_root/"
bump_rc=0
(cd "$bump_root" && ./scripts/bump-version.sh 1.2.3 >"$TEST_TMP/bump-first.out") || bump_rc=$?
assert_eq 0 "$bump_rc" 'bump-version accepts a semantic version in an isolated copy'
# The rewritten documents keep their mode: a 0600 CHANGELOG (mktemp's default) made the
# installer fail for any other account, including the non-root CI lane.
chmod 644 "$bump_root/CHANGELOG.md" "$bump_root/.agents/README.md"
(cd "$bump_root" && ./scripts/bump-version.sh 1.2.4 >/dev/null) || true
assert_eq 644 "$(stat -c '%a' "$bump_root/CHANGELOG.md")" 'bump-version keeps CHANGELOG.md world-readable'
assert_eq 644 "$(stat -c '%a' "$bump_root/.agents/README.md")" 'bump-version keeps .agents/README.md world-readable'
(cd "$bump_root" && ./scripts/bump-version.sh 1.2.3 >/dev/null 2>&1) || true
bump_hash_before=$(sha256sum "$bump_root/keepalive" "$bump_root/README.md" "$bump_root/VALIDATION.md" \
    "$bump_root/docs/VALIDATION.md" "$bump_root/.agents/README.md" "$bump_root/CHANGELOG.md")
bump_rc=0
(cd "$bump_root" && ./scripts/bump-version.sh 1.2.3 >"$TEST_TMP/bump-second.out") || bump_rc=$?
bump_hash_after=$(sha256sum "$bump_root/keepalive" "$bump_root/README.md" "$bump_root/VALIDATION.md" \
    "$bump_root/docs/VALIDATION.md" "$bump_root/.agents/README.md" "$bump_root/CHANGELOG.md")
assert_eq 0 "$bump_rc" 'bump-version is idempotent on the second invocation'
assert_eq "$bump_hash_before" "$bump_hash_after" 'idempotent bump leaves all release files byte-identical'
heading_count=$(grep -Ec '^## \[1\.2\.3\] - [0-9]{4}-[0-9]{2}-[0-9]{2}$' "$bump_root/CHANGELOG.md" || true)
assert_eq 1 "$heading_count" 'bump-version inserts exactly one dated changelog heading'

# The dev-check changelog helper must treat version dots literally and honor heading boundaries.
dev_check_lib="$TEST_TMP/dev-check-lib.sh"
sed '/^main "\$@"/d' "$TEST_ROOT/scripts/dev-check.sh" >"$dev_check_lib"
# shellcheck disable=SC1090
source "$dev_check_lib"
changelog_semantics="$TEST_TMP/changelog-semantics.md"
printf '%s\n' '## [1.1.0] - real' >"$changelog_semantics"
assert_true 'dev-check changelog_has_version accepts the exact release heading' \
    changelog_has_version 1.1.0 "$changelog_semantics"
bogus_changelog="$TEST_TMP/changelog-bogus.md"
printf '%s\n' '## [1x1x0] - bogus' >"$bogus_changelog"
assert_false 'dev-check changelog_has_version rejects regex-like bogus headings' \
    changelog_has_version 1.1.0 "$bogus_changelog"
printf '%s\n' '## [1.1.0]extra' >"$bogus_changelog"
assert_false 'dev-check changelog_has_version requires a heading boundary' \
    changelog_has_version 1.1.0 "$bogus_changelog"

# The aggregate runner must reject both a failing summary with exit 0 and a missing summary.
runner_tests="$TEST_TMP/runner/tests"
mkdir -p "$runner_tests"
cp -- "$TEST_ROOT/tests/run.sh" "$runner_tests/run.sh"
cat >"$runner_tests/test_failing_summary.sh" <<'EOF'
#!/usr/bin/env bash
printf 'not ok 1 - deliberate failure\n'
printf '# 1/1 assertions failed\n'
exit 0
EOF
cat >"$runner_tests/test_missing_summary.sh" <<'EOF'
#!/usr/bin/env bash
printf 'ok 1 - no summary\n'
exit 0
EOF
runner_output="$TEST_TMP/runner.out"
runner_rc=0
(cd "$runner_tests" && bash ./run.sh) >"$runner_output" 2>&1 || runner_rc=$?
assert_true 'tests/run.sh rejects a failing-summary file that exits zero' test "$runner_rc" -ne 0
assert_contains "$runner_output" 'reported a failing or conflicting summary' \
    'tests/run.sh identifies the failing summary despite exit status zero'
assert_contains "$runner_output" 'printed no assertion summary' \
    'tests/run.sh identifies a test with no summary'

test_finish
