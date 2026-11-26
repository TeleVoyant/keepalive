#!/usr/bin/env bash
# Orca fixture corpus and normalized adapter contract, including 1.4.274 compatibility.
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core

parser=${KEEPALIVE_ORCA_PARSER:-auto}
if [[ $parser == auto ]]; then
    if command -v jq >/dev/null 2>&1; then parser='jq'; else parser='awk'; fi
fi
if [[ $parser == jq ]] && ! command -v jq >/dev/null 2>&1; then
    test_skip 'Orca contract tests' 'KEEPALIVE_ORCA_PARSER=jq but jq is not installed'
    test_finish
    exit
fi

export KEEPALIVE_ORCA_ENABLED=1
export KEEPALIVE_ORCA_CLI="$TEST_ROOT/tests/fixtures/orca-mock"
export KEEPALIVE_ORCA_PARSER=$parser
if [[ $parser == jq ]]; then
    KEEPALIVE_JQ=${KEEPALIVE_JQ:-$(command -v jq)}
    export KEEPALIVE_JQ
else
    KEEPALIVE_AWK=${KEEPALIVE_AWK:-$(command -v awk)}
    export KEEPALIVE_AWK
fi
KA_ORCA_CLI=''
KA_ORCA_JQ=''
assert_true "Orca contract test resolves the isolated CLI and $parser reader" ka_orca_find

# Role: Enable one fixture switch and expose its temporary marker through REPLY.
enable_switch() {
    local name=$1 path
    path="$TEST_TMP/switch-$name"
    : >"$path"
    printf -v "FAKE_ORCA_${name}_FILE" '%s' "$path"
    export "FAKE_ORCA_${name}_FILE"
    REPLY=$path
}

# Role: Disable one fixture switch without disturbing unrelated test markers.
disable_switch() {
    local name=$1 variable
    variable="FAKE_ORCA_${name}_FILE"
    unset "$variable"
}

# Role: Invoke show validation while retaining its non-zero return code in REPLY.
run_show_rc() {
    if ka_orca_validate_target "$ORCA_HANDLE" "$ORCA_PTY" "$ORCA_INCARNA" \
        "$ORCA_WORKTREE" "$ORCA_RUNTIME" "$ORCA_HOST" "$ORCA_TAB" "$ORCA_LEAF" "$ORCA_AGENT"; then
        REPLY=0
    else
        REPLY=$?
    fi
    return 0
}

# Role: Assert one exact discovery gate marker from the normalized adapter.
assert_discovery_gate() {
    local expected=$1 label=$2 output
    output=$(ka_orca_discover)
    assert_eq $'#INCOMPLETE\t'"$expected" "$output" "$label"
}

# Role: Check a surrogate-escape list fixture yields every eligible row and the expected title.
assert_surrogate_discovery_title() {
    local fixture=$1 expected=$2 label=$3 output rows row
    local actual_title
    export FAKE_ORCA_LIST_JSON_FILE="$fixture_dir/$fixture"
    output=$(ka_orca_discover)
    rows=$(printf '%s\n' "$output" | sed '/^#/d;/^$/d' | wc -l)
    assert_true "$label retains the one eligible agent row" test "$rows" -eq 1
    assert_eq '#COMPLETE' "$(printf '%s\n' "$output" | tail -n1)" "$label completes discovery"
    row=$(printf '%s\n' "$output" | sed '/^#/d;/^$/d')
    IFS=$'\t' read -r _ _ actual_title _ _ _ _ _ _ _ _ _ <<<"$row"
    assert_eq "$expected" "$actual_title" "$label display title"
}

# Role: Assert one exact show validation return code.
assert_show_rc() {
    local expected=$1 label=$2
    run_show_rc
    assert_eq "$expected" "$REPLY" "$label"
}

# Role: Assert a normalized row has no empty field that could shift its TSV columns.
assert_no_empty_fields() {
    local row=$1 label=$2 empty=0
    local field
    while IFS=$'\t' read -r -a fields; do
        for field in "${fields[@]}"; do
            [[ -n $field ]] || empty=1
        done
    done <<<"$row"
    assert_eq 0 "$empty" "$label"
}

# Role: Write one JSON fixture with a lone high escape in the selected string field.
write_high_escape_field() {
    local source=$1 field=$2 destination=$3
    sed "s/\"$field\"[[:space:]]*:[[:space:]]*\"[^\"]*\"/\"$field\":\"\\\\ud83d\"/" \
        "$source" >"$destination"
}

# Role: Compare the normalizer's shared REPLY register without putting large JSON in argv.
reply_matches_expected() {
    [[ $REPLY == "$EXPECTED_RESPONSE" ]]
}

# Role: Create one exact-size compact list line with a lone high escape in its title.
make_line_cap_list() {
    local destination=$1 target_bytes=$2 prefix suffix filler
    prefix='{"id":"line-cap","ok":true,"result":{"terminals":[{"handle":"cap-handle","ptyId":"cap-pty","incarnationId":"cap-inc","worktreeId":"repo::/cap","worktreePath":"/cap","executionHostId":"local","tabId":"cap-tab","leafId":"cap-leaf","agentIdentity":"codex","title":"'
    suffix='","connected":true,"writable":true,"orphaned":false}],"truncated":false,"totalCount":1},"_meta":{"runtimeId":"runtime-cap"}}'
    filler=$((target_bytes - ${#prefix} - 6 - ${#suffix}))
    ((filler >= 0)) || return 1
    {
        printf '%s' "$prefix"
        printf '%*s' "$filler" '' | tr ' ' a
        printf '\\ud83d%s\n' "$suffix"
    } >"$destination"
}

# Role: Build a valid five-row list with candidate display lines near the aggregate work cap.
make_aggregate_work_list() {
    local destination=$1 target_bytes=$2 extra_high=$3 index row_prefix row_suffix filler
    {
        printf '%s\n' '{"id":"aggregate-cap","ok":true,"result":{"terminals":['
        for index in 1 2 3 4 5; do
            row_prefix='{"handle":"aggregate-handle-'"$index"'","ptyId":"aggregate-pty-'"$index"'","incarnationId":"aggregate-inc-'"$index"'","worktreeId":"repo::/aggregate","worktreePath":"/aggregate","executionHostId":"local","tabId":"aggregate-tab-'"$index"'","leafId":"aggregate-leaf-'"$index"'","agentIdentity":"codex","title":"'
            row_suffix='\ud83d","connected":true,"writable":true,"orphaned":false}'
            if ((index <= 4)); then
                filler=$((target_bytes - ${#row_prefix} - ${#row_suffix}))
                ((filler >= 0)) || return 1
                printf '%s' "$row_prefix"
                printf '%*s' "$filler" '' | tr ' ' a
                printf '%s\n' "$row_suffix"
            elif ((extra_high == 1)); then
                printf '%s%s\n' "$row_prefix" "$row_suffix"
            else
                printf '%ssafe","connected":true,"writable":true,"orphaned":false}\n' "$row_prefix"
            fi
            ((index == 5)) || printf ',\n'
        done
        printf '%s\n' '],"truncated":false,"totalCount":5},"_meta":{"runtimeId":"runtime-aggregate"}}'
    } >"$destination"
}

# The 1.4.274 fixtures reconstruct read-only status/list/show fields captured from the
# installed CLI; every private value is replaced with a synthetic placeholder. The two
# prompt receipts are synthetic and source-derived from the installed 1.4.274 terminal.send
# contract: prompt.stages advances from input_accepted to turn_started. The live 1.4.277
# status, list, and show envelopes have the same structure. The older corpus fixtures remain
# unchanged; the exitCause cases further down are synthetic.
fixture_dir="$TEST_ROOT/tests/fixtures/orca-corpus"
export FAKE_ORCA_STATUS_JSON_FILE="$fixture_dir/status-1.4.274-synthetic.json"
assert_true '1.4.274 status envelope remains reachable' ka_orca_runtime_reachable
assert_true '1.4.274 status fixture contains appVersion' \
    grep -Fq '"appVersion":"1.4.274"' "$fixture_dir/status-1.4.274-synthetic.json"
assert_true '1.4.274 status fixture contains additive capabilities' \
    grep -Fq '"capabilities":["synthetic-capability.v1"]' "$fixture_dir/status-1.4.274-synthetic.json"
unset FAKE_ORCA_STATUS_JSON_FILE

export FAKE_ORCA_LIST_JSON_FILE="$fixture_dir/list-1.4.274-synthetic.json"
latest_discovery=$(ka_orca_discover)
assert_eq 9 "$(printf '%s\n' "$latest_discovery" | sed '/^#/d;/^$/d' | wc -l)" \
    '1.4.274 additive list fields preserve all nine agent candidates'
assert_eq '#COMPLETE' "$(printf '%s\n' "$latest_discovery" | tail -n1)" \
    '1.4.274 reconstructed list completes'
assert_true '1.4.274 list fixture contains hostScope' \
    grep -Fq '"hostScope"' "$fixture_dir/list-1.4.274-synthetic.json"
assert_true '1.4.274 list fixture contains topologyRevisions' \
    grep -Fq '"topologyRevisions"' "$fixture_dir/list-1.4.274-synthetic.json"
assert_true '1.4.274 list fixture contains branch, timestamp, and preview fields' \
    grep -Fq '"branch":"synthetic-branch"' "$fixture_dir/list-1.4.274-synthetic.json"
assert_true '1.4.274 list fixture uses synthetic timestamp and preview values' \
    grep -Fq '"lastOutputAt":0,"preview":"synthetic terminal preview"' \
        "$fixture_dir/list-1.4.274-synthetic.json"
assert_true '1.4.274 show fixture contains pane metadata with the expected JSON types' \
    grep -Fq '"paneRuntimeId":0,"rendererGraphEpoch":0,"agentWait":null' \
        "$fixture_dir/show-1.4.274-synthetic.json"
unset FAKE_ORCA_LIST_JSON_FILE

assert_surrogate_discovery_title list-lone-high-title.json $'\uFFFD' 'lone high title'
assert_surrogate_discovery_title list-escaped-backslash-title.json '\\ud83d' 'escaped backslash'
assert_surrogate_discovery_title list-triple-backslash-title.json $'\\\\\uFFFD' 'odd backslash parity'
assert_surrogate_discovery_title list-paired-surrogates-title.json $'\U0001F600' 'valid surrogate pair'
assert_surrogate_discovery_title list-lone-low-title.json $'\uFFFD' 'lone low surrogate'
assert_surrogate_discovery_title list-uppercase-high-title.json $'\uFFFD' 'uppercase high surrogate'
assert_surrogate_discovery_title list-high-title-at-end.json $'end \uFFFD' 'high surrogate at string end'
assert_surrogate_discovery_title list-back-to-back-high-titles.json $'\uFFFD\uFFFD' 'back-to-back high surrogates'
assert_surrogate_discovery_title list-high-then-non-surrogate-unicode-title.json \
    $'\uFFFDA' 'high followed by non-surrogate unicode escape'
unset FAKE_ORCA_LIST_JSON_FILE

# Identity fields are never eligible display values: their malformed escape must remain
# unparseable instead of being rewritten into a different but plausible binding.
ORCA_HANDLE=term-codex ORCA_PTY=repo::/work/corpus@@pty-1 ORCA_INCARNA=inc-corpus-1
ORCA_WORKTREE=repo::/work/corpus ORCA_RUNTIME=runtime-corpus ORCA_HOST=local
ORCA_TAB=tab-corpus-1 ORCA_LEAF=leaf-corpus-1 ORCA_AGENT=codex
for identity_field in handle ptyId incarnationId agentIdentity; do
    identity_list="$TEST_TMP/list-identity-$identity_field.json"
    write_high_escape_field "$fixture_dir/list-lone-high-title.json" "$identity_field" "$identity_list"
    export FAKE_ORCA_LIST_JSON_FILE=$identity_list
    assert_discovery_gate schema:not-json "lone high in list $identity_field fails closed"

    identity_show="$TEST_TMP/show-identity-$identity_field.json"
    write_high_escape_field "$fixture_dir/show-lone-high-title.json" "$identity_field" "$identity_show"
    export FAKE_ORCA_SHOW_JSON_FILE=$identity_show
    assert_show_rc 22 "lone high in show $identity_field is schema code 22"
done
unset FAKE_ORCA_LIST_JSON_FILE FAKE_ORCA_SHOW_JSON_FILE

# The normalizer's key scope is deliberately line-local and applies only to scalar display values.
scope_response=$'{"title":\n"\\ud83d"}'
ka_orca_normalize_response_set "$scope_response"
assert_eq "$scope_response" "$REPLY" 'display value on the line after its key stays unchanged'
scope_response='{"title" : "\ud83d"}'
ka_orca_normalize_response_set "$scope_response"
assert_eq '{"title" : "\ufffd"}' "$REPLY" 'spaces around a display key colon are accepted'
scope_response='{"title":["\ud83d"]}'
ka_orca_normalize_response_set "$scope_response"
assert_eq "$scope_response" "$REPLY" 'array contents under title are not display scalar values'
scope_response='{"branch":"\ud83d","title":"\ud83d"}'
ka_orca_normalize_response_set "$scope_response"
assert_eq '{"branch":"\ud83d","title":"\ufffd"}' "$REPLY" \
    'compact line rewrites title but leaves a non-display key unchanged'
scope_response='{"preview":"\ud83d","message":"\ud83e"}'
ka_orca_normalize_response_set "$scope_response"
assert_eq '{"preview":"\ufffd","message":"\ufffd"}' "$REPLY" \
    'preview and message display values are normalized on their key line'

# The byte line cap makes refusal deterministic before a pathological compact line is scanned.
cap_under_file="$TEST_TMP/line-cap-under.json"
cap_over_file="$TEST_TMP/line-cap-over.json"
make_line_cap_list "$cap_under_file" 65535
make_line_cap_list "$cap_over_file" 65537
cap_under=$(<"$cap_under_file")
EXPECTED_RESPONSE=${cap_under/'\ud83d'/'\ufffd'}
ka_orca_normalize_response_set "$cap_under"
assert_true 'a 65535-byte line is rewritten below the sanitizer cap' reply_matches_expected
export FAKE_ORCA_LIST_JSON_FILE=$cap_under_file
assert_eq '#COMPLETE' "$(ka_orca_discover | tail -n1)" \
    'a lone high on a line just under the cap completes discovery'
cap_over=$(<"$cap_over_file")
EXPECTED_RESPONSE=$cap_over
ka_orca_normalize_response_set "$cap_over"
assert_true 'a 65537-byte line is passed through unchanged above the sanitizer cap' reply_matches_expected
export FAKE_ORCA_LIST_JSON_FILE=$cap_over_file
assert_discovery_gate schema:not-json 'an over-cap lone high deterministically refuses the list'
unset FAKE_ORCA_LIST_JSON_FILE

# The aggregate cap sums only candidate lines at or below the per-line cap.
aggregate_under_file="$TEST_TMP/aggregate-work-under.json"
aggregate_over_file="$TEST_TMP/aggregate-work-over.json"
make_aggregate_work_list "$aggregate_under_file" 65535 0
aggregate_under=$(<"$aggregate_under_file")
aggregate_under_work=$(LC_ALL=C awk '/\\u[dD][89aAbB][0-9a-fA-F][0-9a-fA-F]/ { total += length($0) } END { print total + 0 }' \
    "$aggregate_under_file")
assert_eq 262140 "$aggregate_under_work" 'aggregate candidate lines total four bytes under the work cap'
EXPECTED_RESPONSE=${aggregate_under//'\ud83d'/'\ufffd'}
ka_orca_normalize_response_set "$aggregate_under"
assert_true 'aggregate work just under 262144 bytes rewrites every candidate line' reply_matches_expected
export FAKE_ORCA_LIST_JSON_FILE=$aggregate_under_file
aggregate_under_output=$(ka_orca_discover)
assert_eq 5 "$(printf '%s\n' "$aggregate_under_output" | sed '/^#/d;/^$/d' | wc -l)" \
    'aggregate work just under the cap keeps all five rows'
assert_eq '#COMPLETE' "$(printf '%s\n' "$aggregate_under_output" | tail -n1)" \
    'aggregate work just under the cap completes discovery'

make_aggregate_work_list "$aggregate_over_file" 65536 1
aggregate_over=$(<"$aggregate_over_file")
aggregate_over_work=$(LC_ALL=C awk '/\\u[dD][89aAbB][0-9a-fA-F][0-9a-fA-F]/ { total += length($0) } END { print total + 0 }' \
    "$aggregate_over_file")
aggregate_extra_line=$(LC_ALL=C awk 'NR == 10 { print length($0); exit }' "$aggregate_over_file")
assert_eq 262144 "$((aggregate_over_work - aggregate_extra_line))" \
    'four maximum-size candidate lines consume exactly the aggregate cap'
assert_true 'one additional candidate line pushes work just over 262144 bytes' \
    test "$aggregate_over_work" -gt 262144
EXPECTED_RESPONSE=$aggregate_over
ka_orca_normalize_response_set "$aggregate_over"
assert_true 'aggregate work over the cap passes every candidate line through unchanged' reply_matches_expected
export FAKE_ORCA_LIST_JSON_FILE=$aggregate_over_file
assert_discovery_gate schema:not-json 'aggregate work over the cap fails closed'
unset FAKE_ORCA_LIST_JSON_FILE

# Count actual wrapper execs, proving the ordinary response path forks neither parser nor timeout.
process_shim_dir="$TEST_TMP/no-normalizer-process-bin"
process_log="$TEST_TMP/no-normalizer-process.log"
mkdir -p "$process_shim_dir"
real_awk=$(command -v awk)
real_timeout=$(command -v timeout)
process_original_keepalive_awk=${KEEPALIVE_AWK:-}
process_original_ka_orca_awk=$KA_ORCA_AWK
cat >"$process_shim_dir/awk" <<'SH'
#!/usr/bin/env bash
printf 'awk\n' >>"$NORMALIZER_PROCESS_LOG"
exec "$NORMALIZER_REAL_AWK" "$@"
SH
cat >"$process_shim_dir/timeout" <<'SH'
#!/usr/bin/env bash
printf 'timeout\n' >>"$NORMALIZER_PROCESS_LOG"
exec "$NORMALIZER_REAL_TIMEOUT" "$@"
SH
chmod 700 "$process_shim_dir/awk" "$process_shim_dir/timeout"
saved_path=$PATH
PATH="$process_shim_dir:$PATH"
KEEPALIVE_AWK=$process_shim_dir/awk KA_ORCA_AWK=''
export PATH KEEPALIVE_AWK KA_ORCA_AWK NORMALIZER_PROCESS_LOG=$process_log NORMALIZER_REAL_AWK=$real_awk
export NORMALIZER_REAL_TIMEOUT=$real_timeout
ka_orca_normalize_response_set '{"ordinary":"response"}'
PATH=$saved_path
KEEPALIVE_AWK=$process_original_keepalive_awk KA_ORCA_AWK=$process_original_ka_orca_awk
export PATH KEEPALIVE_AWK KA_ORCA_AWK
assert_eq '{"ordinary":"response"}' "$REPLY" 'ordinary response is returned unchanged'
assert_true 'ordinary response starts no extra awk or timeout process' test ! -e "$process_log"
unset NORMALIZER_PROCESS_LOG NORMALIZER_REAL_AWK NORMALIZER_REAL_TIMEOUT

# A jq reader still delegates normalization to ka_orca_locate_awk's KEEPALIVE_AWK choice.
original_keepalive_awk=${KEEPALIVE_AWK:-}
if [[ $parser == jq ]]; then
    selection_log="$TEST_TMP/jq-normalizer-awk.log"
    selection_shim="$TEST_TMP/jq-normalizer-awk"
    selected_real_awk=$(command -v awk)
    cat >"$selection_shim" <<'SH'
#!/usr/bin/env bash
printf 'used\n' >>"$JQ_NORMALIZER_AWK_LOG"
exec "$JQ_NORMALIZER_REAL_AWK" "$@"
SH
    chmod 700 "$selection_shim"
    export JQ_NORMALIZER_AWK_LOG=$selection_log JQ_NORMALIZER_REAL_AWK=$selected_real_awk
    KEEPALIVE_ORCA_PARSER=jq KEEPALIVE_AWK=$selection_shim
    export KEEPALIVE_ORCA_PARSER KEEPALIVE_AWK
    KA_ORCA_CLI=''; KA_ORCA_JQ=''; KA_ORCA_AWK=''
    assert_true 'jq mode resolves its selected normalizer awk' ka_orca_find
    ka_orca_normalize_response_set '{"title":"\ud83d"}'
    assert_eq '{"title":"\ufffd"}' "$REPLY" 'jq mode normalizes with the selected awk'
    assert_eq 1 "$(wc -l <"$selection_log")" 'jq mode invoked KEEPALIVE_AWK once'
    KEEPALIVE_AWK=$original_keepalive_awk
    KEEPALIVE_ORCA_PARSER=$parser
    export KEEPALIVE_AWK KEEPALIVE_ORCA_PARSER
    KA_ORCA_CLI=''; KA_ORCA_JQ=''; KA_ORCA_AWK=''
    ka_orca_find
else
    test_skip 'jq mode uses KEEPALIVE_AWK for normalization' 'jq reader is not selected'
fi
unset JQ_NORMALIZER_AWK_LOG JQ_NORMALIZER_REAL_AWK

# Failed and timed-out sanitizer calls preserve the original bytes for the selected reader.
selected_reader_awk=$KA_ORCA_AWK
if [[ $parser == awk ]]; then normalizer_real_awk=$selected_reader_awk; else normalizer_real_awk=$(command -v awk); fi
normalizer_failure_shim="$TEST_TMP/normalizer-failure-awk"
cat >"$normalizer_failure_shim" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
for argument in "$@"; do
    if [[ $argument == op=sanitize ]]; then
        if [[ ${NORMALIZER_FAILURE_MODE:-exit} == timeout ]]; then sleep 2; fi
        exit 1
    fi
done
exec "$NORMALIZER_FAILURE_REAL_AWK" "$@"
SH
chmod 700 "$normalizer_failure_shim"
KEEPALIVE_AWK=$normalizer_failure_shim
if [[ $parser == awk ]]; then KA_ORCA_AWK=$normalizer_failure_shim; else KA_ORCA_AWK=''; fi
KEEPALIVE_ORCA_TIMEOUT=1
NORMALIZER_FAILURE_REAL_AWK=$normalizer_real_awk
NORMALIZER_FAILURE_MODE='exit'
export KEEPALIVE_AWK KA_ORCA_AWK KEEPALIVE_ORCA_TIMEOUT NORMALIZER_FAILURE_REAL_AWK NORMALIZER_FAILURE_MODE
failure_response=$(<"$fixture_dir/list-lone-high-title.json")
EXPECTED_RESPONSE=$failure_response
ka_orca_normalize_response_set "$failure_response"
assert_true 'exit-1 normalizer failure preserves the original REPLY' reply_matches_expected
export FAKE_ORCA_LIST_JSON_FILE="$fixture_dir/list-lone-high-title.json"
assert_discovery_gate schema:not-json 'reader sees the unnormalized response after exit-1'
NORMALIZER_FAILURE_MODE=timeout
export NORMALIZER_FAILURE_MODE
failure_response=$(<"$fixture_dir/show-lone-high-title.json")
EXPECTED_RESPONSE=$failure_response
ka_orca_normalize_response_set "$failure_response"
assert_true 'timed-out normalizer preserves the original REPLY' reply_matches_expected
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-lone-high-title.json"
assert_show_rc 22 'reader returns no-normalization show code after timeout'
unset FAKE_ORCA_LIST_JSON_FILE FAKE_ORCA_SHOW_JSON_FILE KEEPALIVE_ORCA_TIMEOUT
KEEPALIVE_AWK=$original_keepalive_awk
KA_ORCA_AWK=$selected_reader_awk
export KEEPALIVE_AWK KA_ORCA_AWK
unset NORMALIZER_FAILURE_MODE NORMALIZER_FAILURE_REAL_AWK

export FAKE_ORCA_STATUS_JSON_FILE="$fixture_dir/status-lone-high-display.json"
assert_true 'status with lone high display text remains reachable' ka_orca_runtime_reachable
unset FAKE_ORCA_STATUS_JSON_FILE
export FAKE_ORCA_RESPONSE_FILE="$fixture_dir/send-lone-high-display.json"
assert_true 'send receipt with lone high display text remains accepted' \
    ka_orca_deliver term-codex MESSAGE_ENTER synthetic-prompt 0
unset FAKE_ORCA_RESPONSE_FILE
error_lone_high=$(<"$fixture_dir/error-lone-high-message.json")
ka_orca_error_code "$error_lone_high"
assert_eq terminal_handle_stale "$REPLY" 'error code survives lone high display message'

ORCA_HANDLE=term-fixture-1 ORCA_PTY=pty-fixture-1 ORCA_INCARNA=inc-fixture-1
ORCA_WORKTREE=repo::/work/orca-fixture-1 ORCA_RUNTIME=runtime-fixture ORCA_HOST=local
ORCA_TAB=tab-fixture-1 ORCA_LEAF=leaf-fixture-1 ORCA_AGENT=codex
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-1.4.274-synthetic.json"
assert_true '1.4.274 show with paneRuntimeId, rendererGraphEpoch, and agentWait validates' \
    ka_orca_validate_target "$ORCA_HANDLE" "$ORCA_PTY" "$ORCA_INCARNA" \
    "$ORCA_WORKTREE" "$ORCA_RUNTIME" "$ORCA_HOST" "$ORCA_TAB" "$ORCA_LEAF" "$ORCA_AGENT"
unset FAKE_ORCA_SHOW_JSON_FILE

ORCA_HANDLE=term-codex ORCA_PTY=repo::/work/corpus@@pty-1 ORCA_INCARNA=inc-corpus-1
ORCA_WORKTREE=repo::/work/corpus ORCA_RUNTIME=runtime-corpus ORCA_HOST=local
ORCA_TAB=tab-corpus-1 ORCA_LEAF=leaf-corpus-1 ORCA_AGENT=codex
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-lone-high-title.json"
assert_show_rc 0 'show with lone high display title validates'
unset FAKE_ORCA_SHOW_JSON_FILE
ORCA_HANDLE=term-fixture-1 ORCA_PTY=pty-fixture-1 ORCA_INCARNA=inc-fixture-1
ORCA_WORKTREE=repo::/work/orca-fixture-1 ORCA_RUNTIME=runtime-fixture ORCA_HOST=local
ORCA_TAB=tab-fixture-1 ORCA_LEAF=leaf-fixture-1 ORCA_AGENT=codex

for stage_fixture in send-prompt-input-accepted-1.4.274-synthetic.json \
    send-prompt-turn-started-1.4.274-synthetic.json; do
    stage_path="$fixture_dir/$stage_fixture"
    assert_true "$stage_fixture fixture contains the input acceptance stage" \
        grep -Fq '"input_accepted"' "$stage_path"
    if [[ $stage_fixture == *turn-started* ]]; then
        assert_true 'turn-started receipt fixture contains the additional submission stage' \
            grep -Fq '"turn_started"' "$stage_path"
    fi
    export FAKE_ORCA_RESPONSE_FILE="$stage_path"
    assert_true "adapter accepts source-derived $stage_fixture receipt" \
        ka_orca_deliver term-fixture-1 MESSAGE_ENTER synthetic-prompt 0
done
unset FAKE_ORCA_RESPONSE_FILE

# A live-shaped response has the authoritative list/show fields.
export FAKE_ORCA_LIVE_FIVE_FILE=/dev/null
live_json=$("$KEEPALIVE_ORCA_CLI" terminal list --limit 1000 --json)
if [[ $parser == jq && -n ${KEEPALIVE_JQ:-} ]]; then
    assert_eq 6 "$("$KEEPALIVE_JQ" '.result.terminals | length' <<<"$live_json")" \
        'fixture list contains five agent-shaped rows and one shell row'
    assert_eq false "$("$KEEPALIVE_JQ" '.result.truncated' <<<"$live_json")" \
        'fixture list carries the truncation marker'
    assert_eq 6 "$("$KEEPALIVE_JQ" '.result.totalCount' <<<"$live_json")" \
        'fixture list carries totalCount'
    assert_eq 1 "$("$KEEPALIVE_JQ" '.result.topologyRevisions["fixture-worktree"]' <<<"$live_json")" \
        'fixture list carries topology revisions'
    assert_eq runtime-1111 "$("$KEEPALIVE_JQ" -r '.result.hostScope.hostIds[0]' <<<"$live_json")" \
        'fixture list carries host scope'
    assert_eq null "$("$KEEPALIVE_JQ" -c '.result.terminals[5].agentIdentity // null' <<<"$live_json")" \
        'fixture shell row omits agentIdentity'
else
    assert_true 'fixture list contains five agent-shaped rows and one shell row' \
        grep -Fq '"handle":"term_live-5"' <<<"$live_json"
    assert_true 'fixture list carries the truncation marker' grep -Fq '"truncated":false' <<<"$live_json"
    assert_true 'fixture list carries totalCount' grep -Fq '"totalCount":6' <<<"$live_json"
    assert_true 'fixture list carries topology revisions' grep -Fq '"fixture-worktree":1' <<<"$live_json"
    assert_true 'fixture list carries host scope' grep -Fq '"hostIds":["runtime-1111"]' <<<"$live_json"
    assert_eq 5 "$(grep -o '"agentIdentity"' <<<"$live_json" | wc -l)" \
        'fixture shell row omits agentIdentity'
fi
live_show=$("$KEEPALIVE_ORCA_CLI" terminal show --terminal term_mock-agent --json)
if [[ $parser == jq && -n ${KEEPALIVE_JQ:-} ]]; then
    assert_eq fixture-pane-runtime "$("$KEEPALIVE_JQ" -r '.result.terminal.paneRuntimeId' <<<"$live_show")" \
        'fixture show carries paneRuntimeId'
    assert_eq 1 "$("$KEEPALIVE_JQ" '.result.terminal.rendererGraphEpoch' <<<"$live_show")" \
        'fixture show carries rendererGraphEpoch'
    assert_eq null "$("$KEEPALIVE_JQ" -c '.result.terminal.agentWait' <<<"$live_show")" \
        'fixture show carries agentWait:null'
else
    assert_true 'fixture show carries paneRuntimeId' grep -Fq '"paneRuntimeId":"fixture-pane-runtime"' <<<"$live_show"
    assert_true 'fixture show carries rendererGraphEpoch' grep -Fq '"rendererGraphEpoch":1' <<<"$live_show"
    assert_true 'fixture show carries agentWait:null' grep -Fq '"agentWait":null' <<<"$live_show"
fi

# The selected reader is invoked once per provider response.  This is conditional only on
# the reader implementation: jq-specific counting becomes awk-specific counting in fallback
# mode, while the observable normalized operations remain identical.
reader_count="$TEST_TMP/orca-reader.count"
reader_shim="$TEST_TMP/orca-reader-shim"
reader_real=$([[ $parser == jq ]] && printf '%s' "${KEEPALIVE_JQ:-$(command -v jq)}" || printf '%s' "${KEEPALIVE_AWK:-$(command -v awk)}")
cat >"$reader_shim" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$ORCA_READER_OPERATION" >>"$ORCA_READER_COUNT"
exec "$ORCA_READER_REAL" "$@"
SH
chmod 700 "$reader_shim"
export ORCA_READER_COUNT="$reader_count" ORCA_READER_REAL="$reader_real"
if [[ $parser == jq ]]; then KEEPALIVE_JQ=$reader_shim; export KEEPALIVE_JQ; else KEEPALIVE_AWK=$reader_shim; export KEEPALIVE_AWK; fi
KA_ORCA_CLI=''; KA_ORCA_JQ=''; KA_ORCA_AWK=''; ka_orca_find
: >"$reader_count"
export ORCA_READER_OPERATION=list
ka_orca_discover >/dev/null
assert_eq 1 "$(wc -l <"$reader_count")" "$parser reader parses one discovery response in one invocation"
: >"$reader_count"
export ORCA_READER_OPERATION=show
assert_true "$parser reader validates one show response" ka_orca_validate_target \
    term_mock-agent repo::/work/Orca-Project@@pty-1 incarnation-2222 \
    repo::/work/Orca-Project runtime-1111 local tab-3333 leaf-4444 codex
assert_eq 1 "$(wc -l <"$reader_count")" "$parser reader parses one show response in one invocation"
: >"$reader_count"
export ORCA_READER_OPERATION=send
assert_true "$parser reader accepts one send receipt" ka_orca_deliver term_mock-agent MESSAGE_ENTER ping 0
assert_eq 1 "$(wc -l <"$reader_count")" "$parser reader parses one send response in one invocation"
: >"$reader_count"
export ORCA_READER_OPERATION=status
assert_true "$parser reader accepts one status response" ka_orca_runtime_reachable
assert_eq 1 "$(wc -l <"$reader_count")" "$parser reader parses one status response in one invocation"

live_discovery=$(ka_orca_discover)
live_rows=$(printf '%s\n' "$live_discovery" | sed '/^#/d')
assert_eq 5 "$(printf '%s\n' "$live_rows" | sed '/^$/d' | wc -l)" \
    'live-shaped discovery keeps all five agent rows'
assert_eq '#COMPLETE' "$(printf '%s\n' "$live_discovery" | tail -n1)" \
    'live-shaped discovery completes'
expected_ids='orca-runtime-1111-incarnation-2222
orca-runtime-1111-incarnation-second
orca-runtime-1111-incarnation-live-3
orca-runtime-1111-incarnation-live-4
orca-runtime-1111-incarnation-live-5'
while IFS=$'\t' read -r live_id _rest; do
    expected_id=$(printf '%s\n' "$expected_ids" | sed -n '1p')
    expected_ids=$(printf '%s\n' "$expected_ids" | sed '1d')
    assert_eq "$expected_id" "$live_id" 'live rows preserve provider order'
    live_row=$(printf '%s\n' "$live_rows" | sed -n '1p')
    live_rows=$(printf '%s\n' "$live_rows" | sed '1d')
    assert_no_empty_fields "$live_row" 'live row has no shifted empty fields'
    assert_eq 12 "$(awk -F '\t' '{print NF}' <<<"$live_row")" \
        'live row has manager ID plus eleven fields'
done <<<"$live_rows"

# One pty-less candidate reproduces the reported 36-hour shape.
enable_switch PTYLESS
ptyless_discovery=$(ka_orca_discover)
assert_eq 4 "$(printf '%s\n' "$ptyless_discovery" | sed '/^#/d' | wc -l)" \
    'pty-less candidate leaves other rows usable'
assert_true 'pty-less candidate emits incomplete-binding skip count' \
    grep -Fq $'#SKIPPED\t1\tincomplete-binding=1' <<<"$ptyless_discovery"
assert_true 'pty-less candidate still emits complete marker' grep -Fq '#COMPLETE' <<<"$ptyless_discovery"
disable_switch PTYLESS

enable_switch FOREIGN
foreign_discovery=$(ka_orca_discover)
assert_true 'foreign candidate is counted and does not poison good rows' \
    grep -Fq $'#SKIPPED\t1\tincomplete-binding=1' <<<"$foreign_discovery"
assert_eq 4 "$(printf '%s\n' "$foreign_discovery" | sed '/^#/d' | wc -l)" \
    'foreign candidate leaves four usable rows'
disable_switch FOREIGN

enable_switch ORPHANED
assert_eq '#COMPLETE' "$(ka_orca_discover)" 'orphaned rows are ineligible'
disable_switch ORPHANED
enable_switch DISCONNECTED
assert_eq '#COMPLETE' "$(ka_orca_discover)" 'disconnected rows are ineligible'
disable_switch DISCONNECTED
enable_switch NONCANDIDATE_WRONG_BINDING
assert_eq 5 "$(printf '%s\n' "$(ka_orca_discover)" | sed '/^#/d' | wc -l)" \
    'wrong binding on a non-candidate is ignored'
disable_switch NONCANDIDATE_WRONG_BINDING

# Collisions are judged before incomplete rows are dropped.
unset FAKE_ORCA_LIVE_FIVE_FILE
enable_switch EXACT_DUPLICATE
assert_eq 1 "$(printf '%s\n' "$(ka_orca_discover)" | sed '/^#/d' | wc -l)" \
    'exact complete duplicate coalesces'
disable_switch EXACT_DUPLICATE
enable_switch CONFLICTING_DUPLICATE
assert_eq $'#SKIPPED\t2\tambiguous-incarnation=2\n#COMPLETE' "$(ka_orca_discover)" \
    'conflicting duplicates are all skipped'
disable_switch CONFLICTING_DUPLICATE
enable_switch INCOMPLETE_DUPLICATE
assert_eq $'#SKIPPED\t2\tambiguous-incarnation=2\n#COMPLETE' "$(ka_orca_discover)" \
    'complete plus incomplete duplicate is ambiguous'
disable_switch INCOMPLETE_DUPLICATE

# Display text is safe while binding controls remain non-projectable.
export FAKE_ORCA_TITLE=$'safe\tname\nline'
title_output=$(ka_orca_discover)
IFS=$'\t' read -r _ _ title_name _rest <<<"$(printf '%s\n' "$title_output" | sed -n '1p')"
assert_eq safenameline "$title_name" 'title controls are stripped'
unset FAKE_ORCA_TITLE
export FAKE_ORCA_PATH=$'/work/a\tbad'
assert_eq $'#SKIPPED\t1\tincomplete-binding=1\n#COMPLETE' "$(ka_orca_discover)" \
    'binding controls are skipped without shifting fields'
unset FAKE_ORCA_PATH
export FAKE_ORCA_AGENT='#COMPLETE'
assert_eq $'#SKIPPED\t1\tincomplete-binding=1\n#COMPLETE' "$(ka_orca_discover)" \
    'provider agent text cannot forge a marker'
unset FAKE_ORCA_AGENT
export FAKE_ORCA_PATH=/work/project
enable_switch NULL_TITLE
IFS=$'\t' read -r _ _ fallback_name _rest <<<"$(ka_orca_discover | sed -n '1p')"
assert_eq project "$fallback_name" 'null title falls back to path segment'
disable_switch NULL_TITLE
unset FAKE_ORCA_PATH

# Every envelope/type gate is exercised through the fixture, not jq internals.
enable_switch MISSING_TRUNCATED; assert_discovery_gate schema:truncation-marker 'missing truncation marker'; disable_switch MISSING_TRUNCATED
enable_switch TRUNCATED; assert_discovery_gate schema:truncated 'truncated response'; disable_switch TRUNCATED
enable_switch MISSING_TOTAL_COUNT; assert_discovery_gate schema:total-count 'missing totalCount'; disable_switch MISSING_TOTAL_COUNT
enable_switch TOTAL_COUNT_MISMATCH; assert_discovery_gate schema:total-count 'inconsistent totalCount'; disable_switch TOTAL_COUNT_MISMATCH
enable_switch BAD_SCHEMA; assert_discovery_gate schema:terminals 'wrong terminals type'; disable_switch BAD_SCHEMA
enable_switch NOT_OK; assert_discovery_gate schema:not-ok 'not-ok response'; disable_switch NOT_OK
enable_switch MISSING_RUNTIME; assert_discovery_gate schema:runtime-id 'missing runtime fence'; disable_switch MISSING_RUNTIME
enable_switch WRONG_RUNTIME_TYPE; assert_discovery_gate schema:runtime-id 'wrong runtime fence type'; disable_switch WRONG_RUNTIME_TYPE
enable_switch WRONG_AGENT_TYPE; assert_discovery_gate schema:row-type 'wrong agent type'; disable_switch WRONG_AGENT_TYPE
enable_switch LONG_AGENT
assert_eq $'#SKIPPED\t1\tincomplete-binding=1\n#COMPLETE' "$(ka_orca_discover)" \
    'overlong agent identity is skipped as an incomplete binding'
disable_switch LONG_AGENT
enable_switch WRONG_BINDING_TYPE; assert_discovery_gate schema:binding-type 'wrong binding type'; disable_switch WRONG_BINDING_TYPE
enable_switch OVERSIZED_BINDING
assert_eq $'#SKIPPED\t1\tincomplete-binding=1\n#COMPLETE' "$(ka_orca_discover)" \
    'oversized binding value is skipped as incomplete'
disable_switch OVERSIZED_BINDING
enable_switch OVER_LIMIT; assert_discovery_gate schema:total-count 'more than 1000 rows fails the bounded snapshot gate'; disable_switch OVER_LIMIT
enable_switch EMPTY_LIST
assert_eq '#COMPLETE' "$(ka_orca_discover)" 'an empty bounded list is a complete snapshot'
disable_switch EMPTY_LIST
enable_switch NON_OBJECT; assert_discovery_gate schema:not-object 'non-object envelope'; disable_switch NON_OBJECT
enable_switch MULTI_DOCUMENT; assert_discovery_gate schema:document-count 'multiple documents'; disable_switch MULTI_DOCUMENT
enable_switch STDOUT_NOISE; assert_discovery_gate schema:not-json 'stdout noise'; disable_switch STDOUT_NOISE
enable_switch STDERR_NOISE
assert_true 'stderr noise leaves valid discovery complete' grep -Fq '#COMPLETE' <<<"$(ka_orca_discover)"
disable_switch STDERR_NOISE
malformed_list="$TEST_TMP/malformed-list.json"
printf '{not-json\n' >"$malformed_list"
export FAKE_ORCA_LIST_JSON_FILE="$malformed_list"
assert_discovery_gate schema:not-json 'malformed list'
unset FAKE_ORCA_LIST_JSON_FILE
enable_switch HANG
export KEEPALIVE_ORCA_TIMEOUT=1
assert_discovery_gate command-124 'list timeout'
disable_switch HANG
unset KEEPALIVE_ORCA_TIMEOUT

if [[ $parser == awk ]]; then
    slow_reader="$TEST_TMP/slow-orca-awk"
    cat >"$slow_reader" <<'SH'
#!/usr/bin/env bash
sleep 2
exec "$ORCA_REAL_AWK" "$@"
SH
    chmod 700 "$slow_reader"
    export ORCA_REAL_AWK="$reader_real" KEEPALIVE_ORCA_TIMEOUT=1 KEEPALIVE_AWK="$slow_reader"
    KA_ORCA_AWK=$slow_reader
    assert_discovery_gate schema:parse-timeout 'awk reader parse timeout is schema:parse-timeout'
    KEEPALIVE_AWK=$reader_shim
    KA_ORCA_AWK=$reader_shim
    unset KEEPALIVE_ORCA_TIMEOUT ORCA_REAL_AWK
fi

# Show return codes and error mappings.
ORCA_HANDLE=term_mock-agent ORCA_PTY='repo::/work/Orca-Project@@pty-1' ORCA_INCARNA=incarnation-2222
ORCA_WORKTREE='repo::/work/Orca-Project' ORCA_RUNTIME=runtime-1111 ORCA_HOST=local
ORCA_TAB=tab-3333 ORCA_LEAF=leaf-4444 ORCA_AGENT=codex
export FAKE_ORCA_RUNTIME=runtime-1111 FAKE_ORCA_HANDLE=term_mock-agent
export FAKE_ORCA_PTY="$ORCA_PTY" FAKE_ORCA_INCARNATION="$ORCA_INCARNA"
export FAKE_ORCA_WORKTREE="$ORCA_WORKTREE" FAKE_ORCA_HOST=local FAKE_ORCA_TAB=tab-3333
export FAKE_ORCA_LEAF=leaf-4444 FAKE_ORCA_AGENT=codex
assert_show_rc 0 'valid show'

# Orca 1.4.274+ may keep a closed pane in terminal show with exitCause.kind=operator_close.
# That records a requested close, not certified process death, so the adapter ignores
# exitCause: a closed pane gets the ordinary transient results and the strike budget.
ORCA_HANDLE=term-fixture-1 ORCA_PTY=pty-fixture-1 ORCA_INCARNA=inc-fixture-1
ORCA_WORKTREE=repo::/work/orca-fixture-1 ORCA_RUNTIME=runtime-fixture ORCA_HOST=local
ORCA_TAB=tab-fixture-1 ORCA_LEAF=leaf-fixture-1 ORCA_AGENT=codex
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-operator-close.json"
assert_show_rc 23 'operator_close with matching binding and no agent stays transient'
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-operator-close-agent.json"
assert_show_rc 21 'operator_close with matching binding and agent stays transient'
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-operator-close-wrong-incarnation.json"
assert_show_rc 12 'operator_close cannot override a different incarnation'
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-orphaned-unconfirmed.json"
assert_show_rc 23 'orphaned terminal without recognized cause remains transient'
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-operator-close-connected.json"
assert_show_rc 23 'operator_close on connected terminal is not definitive'
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-operator-close-writable.json"
assert_show_rc 23 'operator_close on writable terminal is not definitive'
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-live-malformed-exit-cause.json"
assert_show_rc 0 'malformed exitCause kind does not invalidate a live row'
export FAKE_ORCA_SHOW_JSON_FILE="$fixture_dir/show-live-unknown-exit-cause.json"
assert_show_rc 0 'unknown exitCause kind does not invalidate a live row'
unset FAKE_ORCA_SHOW_JSON_FILE

ORCA_HANDLE=term_mock-agent ORCA_PTY='repo::/work/Orca-Project@@pty-1' ORCA_INCARNA=incarnation-2222
ORCA_WORKTREE='repo::/work/Orca-Project' ORCA_RUNTIME=runtime-1111 ORCA_HOST=local
ORCA_TAB=tab-3333 ORCA_LEAF=leaf-4444 ORCA_AGENT=codex
export FAKE_ORCA_HANDLE=term_mock-agent FAKE_ORCA_PTY="$ORCA_PTY"
export FAKE_ORCA_INCARNATION="$ORCA_INCARNA" FAKE_ORCA_WORKTREE="$ORCA_WORKTREE"
export FAKE_ORCA_HOST=local FAKE_ORCA_TAB=tab-3333 FAKE_ORCA_LEAF=leaf-4444 FAKE_ORCA_AGENT=codex
enable_switch SHOW_NO_PTY; assert_show_rc 24 'no PTY show'; disable_switch SHOW_NO_PTY
enable_switch SHOW_NO_AGENT; assert_show_rc 23 'no agent show'; disable_switch SHOW_NO_AGENT
enable_switch SHOW_EMPTY_AGENT; assert_show_rc 23 'empty agent show'; disable_switch SHOW_EMPTY_AGENT
enable_switch DISCONNECTED; assert_show_rc 21 'disconnected show'; disable_switch DISCONNECTED
enable_switch NOT_WRITABLE; assert_show_rc 21 'non-writable show'; disable_switch NOT_WRITABLE
enable_switch ORPHANED; assert_show_rc 21 'orphaned show'; disable_switch ORPHANED
export FAKE_ORCA_RUNTIME=runtime-other; assert_show_rc 11 'runtime identity change'; export FAKE_ORCA_RUNTIME=runtime-1111
export FAKE_ORCA_HANDLE=term-other; assert_show_rc 10 'handle identity change'; export FAKE_ORCA_HANDLE=term_mock-agent
export FAKE_ORCA_INCARNATION=inc-other; assert_show_rc 12 'incarnation identity change'; export FAKE_ORCA_INCARNATION="$ORCA_INCARNA"
export FAKE_ORCA_PTY=pty-other; assert_show_rc 13 'PTY identity change'; export FAKE_ORCA_PTY="$ORCA_PTY"
export FAKE_ORCA_WORKTREE=worktree-other; assert_show_rc 14 'worktree identity change'; export FAKE_ORCA_WORKTREE="$ORCA_WORKTREE"
export FAKE_ORCA_HOST=host-other; assert_show_rc 14 'host identity change'; export FAKE_ORCA_HOST=local
export FAKE_ORCA_TAB=tab-other; assert_show_rc 16 'tab identity change'; export FAKE_ORCA_TAB=tab-3333
export FAKE_ORCA_LEAF=leaf-other; assert_show_rc 16 'leaf identity change'; export FAKE_ORCA_LEAF=leaf-4444
export FAKE_ORCA_AGENT=agent-other; assert_show_rc 15 'agent identity change'; export FAKE_ORCA_AGENT=codex
enable_switch SHOW_MISSING_HOST; assert_show_rc 22 'missing host schema'; disable_switch SHOW_MISSING_HOST
enable_switch MISSING_BINDING; assert_show_rc 22 'missing binding schema'; disable_switch MISSING_BINDING
enable_switch SHOW_MISSING_HANDLE; assert_show_rc 22 'missing handle schema'; disable_switch SHOW_MISSING_HANDLE
enable_switch SHOW_MISSING_WORKTREE; assert_show_rc 22 'missing worktree schema'; disable_switch SHOW_MISSING_WORKTREE
enable_switch SHOW_MISSING_TAB; assert_show_rc 22 'missing tab schema'; disable_switch SHOW_MISSING_TAB
enable_switch SHOW_MISSING_LEAF; assert_show_rc 22 'missing leaf schema'; disable_switch SHOW_MISSING_LEAF
enable_switch WRONG_BINDING_TYPE; assert_show_rc 22 'wrong binding type schema'; disable_switch WRONG_BINDING_TYPE
enable_switch SHOW_MISSING_RUNTIME; assert_show_rc 22 'missing runtime schema'; disable_switch SHOW_MISSING_RUNTIME
show_malformed="$TEST_TMP/malformed-show.json"
printf '{not-json\n' >"$show_malformed"
export FAKE_ORCA_SHOW_JSON_FILE="$show_malformed"
assert_show_rc 22 'malformed show'
unset FAKE_ORCA_SHOW_JSON_FILE
enable_switch STDOUT_NOISE; assert_show_rc 22 'show stdout noise schema'; disable_switch STDOUT_NOISE
enable_switch STDERR_NOISE; assert_show_rc 0 'show stderr noise'; disable_switch STDERR_NOISE
enable_switch SHOW_ERROR
for error_code in terminal_handle_stale terminal_gone selector_not_found; do
    export FAKE_ORCA_SHOW_ERROR_CODE="$error_code"
    assert_show_rc 10 "error $error_code maps to stale handle"
done
for error_code in terminal_unsupported_for_agent_session terminal_surface_ownership_unavailable runtime_unavailable unknown; do
    export FAKE_ORCA_SHOW_ERROR_CODE="$error_code"
    assert_show_rc 21 "error $error_code maps to reachability"
done
unset FAKE_ORCA_SHOW_ERROR_CODE
disable_switch SHOW_ERROR
enable_switch HANG; export KEEPALIVE_ORCA_TIMEOUT=1
assert_show_rc 20 'show timeout'; disable_switch HANG; unset KEEPALIVE_ORCA_TIMEOUT

enable_switch OVERSIZE
assert_discovery_gate schema:oversize 'oversized list response is rejected before parsing'
assert_show_rc 22 'oversized show response is schema 22'
assert_false 'oversized send receipt is rejected' ka_orca_deliver term_mock-agent MESSAGE_ENTER ping 0
assert_false 'oversized status response is unreachable' ka_orca_runtime_reachable
oversized_error=$(printf '%*s{}' 4194305 '')
ka_orca_error_code "$oversized_error"
assert_eq unknown "$REPLY" 'oversized error response maps to unknown'
disable_switch OVERSIZE

assert_eq 'Orca terminal reports no agent identity right now' "$(ka_orca_validation_reason 23)" 'reason text for no agent'
assert_eq 'Orca terminal has no attached PTY right now' "$(ka_orca_validation_reason 24)" 'reason text for no PTY'
for code in 20 21 22 23 24; do
    assert_true "code $code is transient" ka_orca_validation_is_transient "$code"
done
assert_false 'code 15 is definitive' ka_orca_validation_is_transient 15
assert_false 'schema does not consume a strike' ka_orca_validation_consumes_strike 22
assert_true 'no-agent consumes a strike' ka_orca_validation_consumes_strike 23
assert_true 'no-PTY consumes a strike' ka_orca_validation_consumes_strike 24

# Doctor status and explicit orca-ide selection.
KA_ORCA_CLI="$TEST_ROOT/tests/fixtures/orca-mock"
if [[ $parser == jq ]]; then KA_ORCA_JQ=$KEEPALIVE_JQ; else KA_ORCA_AWK=$KEEPALIVE_AWK; fi
assert_true 'reachable status passes doctor probe' ka_orca_runtime_reachable
enable_switch UNREACHABLE; assert_false 'unreachable status fails doctor probe' ka_orca_runtime_reachable; disable_switch UNREACHABLE
status_true="$TEST_TMP/status-true.json"
status_false="$TEST_TMP/status-false.json"
status_true_false="$TEST_TMP/status-true-false.json"
status_false_true="$TEST_TMP/status-false-true.json"
cat >"$status_true" <<'JSON'
{"ok":true,"result":{"runtime":{"reachable":true}},"_meta":{"runtimeId":"runtime-1111"}}
JSON
cat >"$status_false" <<'JSON'
{"ok":true,"result":{"runtime":{"reachable":false}},"_meta":{"runtimeId":"runtime-1111"}}
JSON
{ cat "$status_true"; cat "$status_false"; } >"$status_true_false"
{ cat "$status_false"; cat "$status_true"; } >"$status_false_true"
export FAKE_ORCA_STATUS_JSON_FILE="$status_true_false"; assert_false 'true then false status documents fail closed' ka_orca_runtime_reachable
export FAKE_ORCA_STATUS_JSON_FILE="$status_false_true"; assert_false 'false then true status documents fail closed' ka_orca_runtime_reachable
unset FAKE_ORCA_STATUS_JSON_FILE
malformed_status="$TEST_TMP/malformed-status.json"
printf '{not-json\n' >"$malformed_status"
export FAKE_ORCA_STATUS_JSON_FILE="$malformed_status"; assert_false 'malformed status fails doctor probe' ka_orca_runtime_reachable
unset FAKE_ORCA_STATUS_JSON_FILE
enable_switch HANG; export KEEPALIVE_ORCA_TIMEOUT=1
assert_false 'status timeout fails doctor probe' ka_orca_runtime_reachable
disable_switch HANG; unset KEEPALIVE_ORCA_TIMEOUT

mkdir -p "$TEST_TMP/bare-only"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TEST_TMP/bare-only/orca"
chmod 700 "$TEST_TMP/bare-only/orca"
saved_path=$PATH
export PATH="$TEST_TMP/bare-only"
unset KEEPALIVE_ORCA_CLI
KA_ORCA_CLI=''
REPLY=sentinel
assert_false 'locator refuses bare orca' ka_orca_locate_cli
assert_eq '' "$REPLY" 'locator does not return bare-orca path'
export PATH="$saved_path"
export KEEPALIVE_ORCA_CLI="$TEST_ROOT/tests/fixtures/orca-mock"
KA_ORCA_CLI=''
KA_ORCA_JQ=''
assert_true 'explicit fixture CLI remains resolvable' ka_orca_find

test_finish

