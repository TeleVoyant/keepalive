#!/usr/bin/env bash
# Orca jq/awk reader equivalence and parser-selection contract.
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core

export KEEPALIVE_ORCA_ENABLED=1
export KEEPALIVE_ORCA_CLI="$TEST_ROOT/tests/fixtures/orca-mock"

# Role: Run one owned Orca test file under one selected JSON reader and print child output only on failure.
run_reader_test() {
    local parser=$1 binary=$2 script=$3 label=$4 output
    output="$TEST_TMP/${label//[^A-Za-z0-9_.-]/_}.out"
    if env KEEPALIVE_ORCA_PARSER="$parser" KEEPALIVE_AWK="$binary" \
        KEEPALIVE_JQ="${KEEPALIVE_JQ:-}" bash "$script" >"$output" 2>&1; then
        assert_true "$label passes under $parser reader ($binary)" true
    else
        cat "$output"
        assert_true "$label passes under $parser reader ($binary)" false
    fi
}

# Role: Build a PATH containing normal core commands while intentionally omitting jq.
build_no_jq_path() {
    local directory=$1 name source
    mkdir -p "$directory"
    for name in bash awk python3 env mktemp mkdir chmod cat cp rm readlink realpath stat id getent \
        touch uname grep sed tail head wc tr cut timeout sleep date dirname basename sort find; do
        source=$(command -v "$name" || true)
        [[ -n $source && ! -e $directory/$name ]] && ln -s "$source" "$directory/$name"
    done
    REPLY=$directory
}

# Role: Run a shell probe with jq hidden to verify auto parser fallback without touching the host.
run_no_jq_probe() {
    local probe=$1 path=$2 output=$3
    env PATH="$path" TEST_ROOT="$TEST_ROOT" KEEPALIVE_ORCA_CLI="$KEEPALIVE_ORCA_CLI" \
        KEEPALIVE_ORCA_ENABLED=1 KEEPALIVE_ORCA_PARSER=auto bash "$probe" >"$output" 2>&1
}

# Role: Generate compact, pretty-printed, and boundary synthetic JSON files for the differential corpus.
build_corpus() {
    local directory=$1 base row shell index deep
    mkdir -p "$directory"
    base='{"handle":"term-codex","ptyId":"repo::/work/corpus@@pty-1","incarnationId":"inc-corpus-1","worktreeId":"repo::/work/corpus","worktreePath":"/work/corpus","executionHostId":"local","tabId":"tab-corpus-1","leafId":"leaf-corpus-1","agentIdentity":"codex","title":"Corpus Codex","connected":true,"writable":true,"orphaned":false,"branch":"main","lastOutputAt":0,"preview":"synthetic"}'
    shell='{"handle":"term-shell","ptyId":"shell-pty","incarnationId":"shell-inc","worktreeId":"repo::/work/corpus","worktreePath":"/work/corpus","executionHostId":"local","tabId":"tab-shell","leafId":"leaf-shell","title":"Shell","connected":true,"writable":true,"orphaned":false}'
    row='{"handle":"term-codex","ptyId":"repo::/work/corpus@@pty-1","incarnationId":"inc-corpus-1","worktreeId":"repo::/work/corpus","worktreePath":"/work/corpus","executionHostId":"local","tabId":"tab-corpus-1","leafId":"leaf-corpus-1","agentIdentity":"codex","title":"Corpus Codex","connected":true,"writable":true,"orphaned":false}'
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":['"$base,$shell"'],"truncated":false,"totalCount":2,"hostScope":{"hostIds":["local"],"omittedHostIds":[]},"topologyRevisions":{"corpus":1}},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/list-valid.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":['"${row/"ptyId":"repo::\/work\/corpus@@pty-1"/"ptyId":null}"','"${row/"incarnationId":"inc-corpus-1"/"incarnationId":null}"'],"truncated":false,"totalCount":2},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/list-ptyless.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":['"$row,$row"'],"truncated":false,"totalCount":2},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/list-exact-duplicate.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":['"$row"',{"handle":"term-other","ptyId":"pty-other","incarnationId":"inc-corpus-1","worktreeId":"repo::/work/corpus","worktreePath":"/work/corpus","executionHostId":"local","tabId":"tab-other","leafId":"leaf-other","agentIdentity":"codex","title":"Other","connected":true,"writable":true,"orphaned":false}],"truncated":false,"totalCount":2},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/list-collision.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":['"$row"',{"handle":"term-incomplete","ptyId":"pty-other","incarnationId":"inc-corpus-1","worktreeId":"repo::/work/corpus","worktreePath":"/work/corpus","tabId":"tab-other","leafId":"leaf-other","agentIdentity":"codex","title":"Incomplete","connected":true,"writable":true,"orphaned":false}],"truncated":false,"totalCount":2},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/list-incomplete-duplicate.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":['"${row/"title":"Corpus Codex"/"title":"é界🙂"}"'],"truncated":false,"totalCount":1},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/list-unicode.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":['"${row/"title":"Corpus Codex"/"title":"safe\u0000\u001b\u007f\u0085"}"'],"truncated":false,"totalCount":1},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/list-controls.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":['"${row/"worktreePath":"\/work\/corpus"/"worktreePath":"\/work\/é界🙂"}"'],"truncated":false,"totalCount":1},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/list-raw-utf8.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":[],"truncated":false,"totalCount":0},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/list-empty.json"
    for number in 2.0 2e0 2E+0 2.000; do
        number_json=$(<"$directory/list-valid.json")
        number_json=${number_json/\"totalCount\":2/\"totalCount\":$number}
        printf '%s\n' "$number_json" >"$directory/list-number-${number//+/_}.json"
    done
    whitespace_json=$(<"$directory/list-valid.json")
    whitespace_json=${whitespace_json//,/,$'\n'}
    printf '%s\n' "$whitespace_json" >"$directory/list-whitespace.json"
    printf '%s\n' '{"ok":true,"result":{"terminal":{"handle":"term-codex","ptyId":"repo::/work/corpus@@pty-1","incarnationId":"inc-corpus-1","worktreeId":"repo::/work/corpus","worktreePath":"/work/corpus","executionHostId":"local","tabId":"tab-corpus-1","leafId":"leaf-corpus-1","agentIdentity":"codex","connected":true,"writable":true,"orphaned":false}},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/show-valid.json"
    printf '%s\n' '{"ok":true,"result":{"terminal":{"handle":"term-codex","ptyId":null,"incarnationId":null,"worktreeId":"repo::/work/corpus","worktreePath":"/work/corpus","executionHostId":"local","tabId":"tab-corpus-1","leafId":"leaf-corpus-1","agentIdentity":"codex","connected":true,"writable":true,"orphaned":false}},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/show-no-pty.json"
    printf '%s\n' '{"ok":true,"result":{"terminal":{"handle":"term-codex","ptyId":"pty","incarnationId":"inc-corpus-1","worktreeId":"repo::/work/corpus","worktreePath":"/work/corpus","executionHostId":"local","tabId":"tab-corpus-1","leafId":"leaf-corpus-1","connected":true,"writable":true,"orphaned":false}},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/show-no-agent.json"
    printf '%s\n' '{"ok":true,"result":{"terminal":{"handle":"term-codex","ptyId":[],"incarnationId":"inc-corpus-1","worktreeId":"repo::/work/corpus","worktreePath":"/work/corpus","executionHostId":"local","tabId":"tab-corpus-1","leafId":"leaf-corpus-1","agentIdentity":"codex","connected":true,"writable":true,"orphaned":false}},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/show-wrong-type.json"
    printf '%s\n' '{"ok":true,"result":{"send":{"handle":"term-codex","accepted":true}},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/send-valid.json"
    printf '%s\n' '{"ok":true,"result":{"send":{"handle":"term-codex","accepted":false}},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/send-rejected.json"
    printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":true}},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/status-reachable.json"
    printf '%s\n' '{"ok":true,"result":{"runtime":{"reachable":false}},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/status-unreachable.json"
    printf '%s\n' '{"ok":false,"error":{"code":"terminal_handle_stale"},"_meta":{"runtimeId":null}}' >"$directory/error-stale.json"
    printf '%s\n' '{"ok":false,"error":{"code":"unknown"},"_meta":{"runtimeId":null}}' >"$directory/error-unknown.json"
    { cat "$directory/error-stale.json"; cat "$directory/error-unknown.json"; } >"$directory/error-multi-document.json"
    printf '%s\n' '{not-json' >"$directory/malformed.json"
    { cat "$directory/list-valid.json"; cat "$directory/list-valid.json"; } >"$directory/list-multi-document.json"
    { cat "$directory/show-valid.json"; cat "$directory/show-valid.json"; } >"$directory/show-multi-document.json"
    { cat "$directory/send-valid.json"; cat "$directory/send-valid.json"; } >"$directory/send-multi-document.json"
    { cat "$directory/status-reachable.json"; cat "$directory/status-reachable.json"; } >"$directory/status-multi-document.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":"changed","truncated":false,"totalCount":0},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/envelope-terminals-wrong.json"
    printf '%s\n' '{"id":"corpus-list","ok":false,"result":{"terminals":[],"truncated":false,"totalCount":0},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/envelope-not-ok.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":[],"totalCount":0},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/envelope-truncation-missing.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":[],"truncated":true,"totalCount":0},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/envelope-truncated.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":[],"truncated":"false","totalCount":0},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/envelope-truncation-wrong.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":[],"truncated":false,"totalCount":0},"_meta":{}}' >"$directory/envelope-runtime-missing.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":[],"truncated":false,"totalCount":0},"_meta":{"runtimeId":5}}' >"$directory/envelope-runtime-wrong.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":[],"truncated":false},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/envelope-total-missing.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":[],"truncated":false,"totalCount":1},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/envelope-total-mismatch.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":[{"handle":{},"connected":true,"writable":true,"orphaned":false}],"truncated":false,"totalCount":1},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/envelope-row-wrong.json"
    printf '%s\n' '{"id":"corpus-list","ok":true,"result":{"terminals":['"${row/"ptyId":"repo::\/work\/corpus@@pty-1"/"ptyId":[]}"'],"truncated":false,"totalCount":1},"_meta":{"runtimeId":"runtime-corpus"}}' >"$directory/envelope-binding-wrong.json"
    printf '%s\n' '[]' >"$directory/envelope-not-object.json"
    # Large snapshots are pretty-printed so BusyBox awk sees one token per line rather
    # than spending its deadline on one enormous compact line. The title is long enough
    # to exercise bounded string retention without making the 1001-row response oversize.
    python3 - "$directory" <<'PY'
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
valid = json.loads((directory / "list-valid.json").read_text(encoding="utf-8"))
template = valid["result"]["terminals"][0]

# Role: Build one large pretty-printed list response with bounded display titles.
def large_document(count):
    terminals = []
    for index in range(count):
        item = dict(template)
        item.update(
            handle=f"term-large-{index}",
            ptyId=f"pty-large-{index}",
            incarnationId=f"inc-large-{index}",
            worktreeId=f"wt-large-{index}",
            worktreePath=f"/work/large-{index}",
            tabId=f"tab-large-{index}",
            leafId=f"leaf-large-{index}",
            title=f"Pretty large terminal {index} " + ("title-" * 40),
        )
        terminals.append(item)
    document = dict(valid)
    document["result"] = dict(valid["result"], terminals=terminals, totalCount=count)
    return document

for count in (100, 1000, 1001):
    (directory / f"list-{count}.json").write_text(
        json.dumps(large_document(count), ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )

(directory / "list-valid-pretty.json").write_text(
    json.dumps(valid, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)

long_title = dict(valid)
long_title["result"] = dict(valid["result"])
long_title["result"]["terminals"] = [dict(template, title="x" * 5000)]
long_title["result"]["totalCount"] = 1
(directory / "list-long-title.json").write_text(
    json.dumps(long_title, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
)
PY
    printf '{"id":"corpus-list","ok":true,"result":{"terminals":[{"handle":"term-codex","ptyId":"pty-good","ptyId":null,"incarnationId":"inc","worktreeId":"wt","worktreePath":"/work","executionHostId":"local","tabId":"tab","leafId":"leaf","agentIdentity":"codex","title":"dup","connected":true,"writable":true,"orphaned":false}],"truncated":false,"totalCount":1},"_meta":{"runtimeId":"runtime-corpus"}}\n' >"$directory/list-duplicate-keys.json"
    # jq 1.7 counts the envelope object in its depth ceiling; use 253/254 for
    # total documents of roughly 255/256, and 256 for the deliberately too-deep case.
    for deep_spec in 255:253 256:254 257:256; do
        IFS=: read -r deep_label deep_depth <<<"$deep_spec"
        deep=0
        for index in $(seq 1 "$deep_depth"); do deep="[$deep"; done
        for index in $(seq 1 "$deep_depth"); do deep+=']'; done
        printf '{"id":"corpus-list","ok":true,"deep":%s,"result":{"terminals":[],"truncated":false,"totalCount":0},"_meta":{"runtimeId":"runtime-corpus"}}\n' \
            "$deep" >"$directory/deep-$deep_label.json"
    done
    # These extra members are deliberately unread by the adapter. Their nesting still
    # exercises the parser stack around jq 1.7's exact 256-entry refusal boundary while
    # the list row itself remains valid and projectable.
    python3 - "$directory" <<'PY'
import json
import pathlib
import sys

directory = pathlib.Path(sys.argv[1])
valid = json.loads((directory / "list-valid.json").read_text(encoding="utf-8"))
row = valid["result"]["terminals"][0]

for kind, depths in (("array", range(248, 257)), ("object", range(122, 129))):
    for depth in depths:
        value = {"leaf": True}
        for _ in range(depth):
            value = [value] if kind == "array" else {"nested": value}
        nested_row = dict(row, extra=value)
        document = dict(valid)
        document["result"] = dict(valid["result"], terminals=[nested_row], totalCount=1)
        (directory / f"deep-row-{kind}-{depth}.json").write_text(
            json.dumps(document, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
PY
    python3 - "$directory/oversize.json" <<'PY'
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_text(" " * 4194305 + "{}\n", encoding="ascii")
PY
    printf '{"id":"corpus-list","ok":true,"result":{"terminals":[{"handle":"term-codex","ptyId":"pty","incarnationId":"inc","worktreeId":"wt","worktreePath":"/work","executionHostId":"local","tabId":"tab","leafId":"leaf","agentIdentity":"codex","title":"raw\xff","connected":true,"writable":true,"orphaned":false}],"truncated":false,"totalCount":1},"_meta":{"runtimeId":"runtime-corpus"}}\n' >"$directory/raw-invalid-utf8.json"
}

# Role: Run one adapter operation in a fresh shell and record stdout plus return status.
run_probe_once() {
    local parser=$1 binary=$2 operation=$3 input=$4 output=$5 rcfile=$6 cli_rc=${7:-0}
    local stderr_file="$output.stderr" rc
    if env TEST_ROOT="$TEST_ROOT" FAKE_ORCA_STUB="$FAKE_ORCA_STUB" FAKE_ORCA_INPUT="$input" \
        FAKE_ORCA_CLI_RC="$cli_rc" PARSER_NAME="$parser" PARSER_BINARY="$binary" \
        bash "$FAKE_ORCA_PROBE" "$operation" >"$output" 2>"$stderr_file"; then
        printf '0\n' >"$rcfile"
    else
        rc=$?
        printf '%s\n' "$rc" >"$rcfile"
    fi
}

# Role: Compare one corpus response through jq and awk, preserving return codes and output bytes.
assert_probe_parity() {
    local operation=$1 input=$2 label=$3 cli_rc=${4:-0}
    local jq_output="$TEST_TMP/probe-jq.out" jq_rc="$TEST_TMP/probe-jq.rc"
    local awk_output="$TEST_TMP/probe-awk.out" awk_rc="$TEST_TMP/probe-awk.rc"
    run_probe_once jq "$JQ_BIN" "$operation" "$input" "$jq_output" "$jq_rc" "$cli_rc"
    run_probe_once awk "$SYSTEM_AWK" "$operation" "$input" "$awk_output" "$awk_rc" "$cli_rc"
    assert_eq "$(<"$jq_rc")" "$(<"$awk_rc")" "$label return code parity"
    if files_equal "$jq_output" "$awk_output"; then
        assert_true "$label output byte parity" true
    else
        printf '%s jq output:\n' "$label"; od -An -tx1c "$jq_output"
        printf '%s awk output:\n' "$label"; od -An -tx1c "$awk_output"
        assert_true "$label output byte parity" false
    fi
}

# Role: Compare compact and pretty-printed JSON through one selected reader.
assert_format_identity() {
    local parser=$1 binary=$2 operation=$3 compact=$4 pretty=$5 label=$6
    local compact_output="$TEST_TMP/compact-$parser.out" compact_rc="$TEST_TMP/compact-$parser.rc"
    local pretty_output="$TEST_TMP/pretty-$parser.out" pretty_rc="$TEST_TMP/pretty-$parser.rc"
    run_probe_once "$parser" "$binary" "$operation" "$compact" "$compact_output" "$compact_rc"
    run_probe_once "$parser" "$binary" "$operation" "$pretty" "$pretty_output" "$pretty_rc"
    assert_eq "$(<"$compact_rc")" "$(<"$pretty_rc")" "$label return code is format-independent ($parser)"
    if files_equal "$compact_output" "$pretty_output"; then
        assert_true "$label output is format-independent ($parser)" true
    else
        printf '%s compact output:\n' "$label"; od -An -tx1c "$compact_output"
        printf '%s pretty output:\n' "$label"; od -An -tx1c "$pretty_output"
        assert_true "$label output is format-independent ($parser)" false
    fi
}

# Role: Check the jq 1.7 observable result at one nested-member depth boundary.
assert_depth_boundary() {
    local input=$1 label=$2 expected=$3
    local output="$TEST_TMP/depth-boundary.out" rcfile="$TEST_TMP/depth-boundary.rc"
    run_probe_once jq "$JQ_BIN" list "$input" "$output" "$rcfile"
    if [[ $expected == complete ]]; then
        assert_true "$label has a complete marker under jq" grep -Fq '#COMPLETE' "$output"
        assert_false "$label has no schema refusal under jq" grep -Fq '#INCOMPLETE' "$output"
    else
        assert_eq 0 "$(<"$rcfile")" "$label returns a normalized parser result under jq"
        assert_eq $'#INCOMPLETE\tschema:not-json' "$(<"$output")" "$label refuses at the jq depth boundary"
    fi
}

# Role: Assert that the sole documented awk-only refusal cannot leak rows or a marker.
assert_awk_refusal() {
    local operation=$1 input=$2 label=$3
    local output="$TEST_TMP/refusal.out" rcfile="$TEST_TMP/refusal.rc"
    run_probe_once awk "$SYSTEM_AWK" "$operation" "$input" "$output" "$rcfile"
    assert_eq 0 "$(<"$rcfile")" "$label returns a normalized result (adapter reports refusal in-band)"
    assert_false "$label emits no normalized rows" grep -Eq '^[^#]' "$output"
    assert_false "$label emits no complete marker" grep -Fq '#COMPLETE' "$output"
}

# Role: Verify doctor names the selected Orca JSON reader without contacting a live runtime.
assert_doctor_reader() {
    local parser=$1 binary=$2 expected=$3 output="$TEST_TMP/doctor-$1.out" rc=0
    if [[ $parser == jq ]]; then
        KEEPALIVE_JQ=$binary
    else
        KEEPALIVE_AWK=$binary
    fi
    env KEEPALIVE_KONSOLE_ENABLED=0 KEEPALIVE_ORCA_ENABLED=1 \
        KEEPALIVE_ORCA_CLI="$TEST_ROOT/tests/fixtures/orca-mock" KEEPALIVE_ORCA_PARSER="$parser" \
        KEEPALIVE_AWK="${KEEPALIVE_AWK:-}" KEEPALIVE_JQ="${KEEPALIVE_JQ:-}" \
        HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" \
        XDG_STATE_HOME="$XDG_STATE_HOME" "$TEST_ROOT/keepalive" doctor >"$output" 2>&1 || rc=$?
    assert_true "$parser doctor invocation completes diagnostics" test "$rc" -ge 0
    assert_true "$parser doctor names its Orca reader" grep -Fq "$expected" "$output"
}

JQ_BIN=$(command -v jq || true)
SYSTEM_AWK=$(command -v awk || true)

# Every available awk implementation gets the same adapter corpus. BusyBox is wrapped so
# KEEPALIVE_AWK still names one executable, matching how users can pin an interpreter.
if [[ -n $SYSTEM_AWK ]]; then
    run_reader_test awk "$SYSTEM_AWK" "$TEST_ROOT/tests/test_orca_contract.sh" system-awk-contract
    run_reader_test awk "$SYSTEM_AWK" "$TEST_ROOT/tests/test_orca_mock.sh" system-awk-mock
fi
if command -v gawk >/dev/null 2>&1; then
    run_reader_test awk "$(command -v gawk)" "$TEST_ROOT/tests/test_orca_contract.sh" gawk-contract
    run_reader_test awk "$(command -v gawk)" "$TEST_ROOT/tests/test_orca_mock.sh" gawk-mock
fi
if command -v mawk >/dev/null 2>&1; then
    run_reader_test awk "$(command -v mawk)" "$TEST_ROOT/tests/test_orca_contract.sh" mawk-contract
    run_reader_test awk "$(command -v mawk)" "$TEST_ROOT/tests/test_orca_mock.sh" mawk-mock
fi
if command -v busybox >/dev/null 2>&1; then
    busybox_awk="$TEST_TMP/busybox-awk"
    cat >"$busybox_awk" <<'SH'
#!/usr/bin/env bash
exec "$BUSYBOX_BINARY" awk "$@"
SH
    chmod 700 "$busybox_awk"
    BUSYBOX_BINARY=$(command -v busybox)
    export BUSYBOX_BINARY
    run_reader_test awk "$busybox_awk" "$TEST_ROOT/tests/test_orca_contract.sh" busybox-awk-contract
    run_reader_test awk "$busybox_awk" "$TEST_ROOT/tests/test_orca_mock.sh" busybox-awk-mock
fi
if [[ -n $JQ_BIN ]]; then
    run_reader_test jq "$JQ_BIN" "$TEST_ROOT/tests/test_orca_contract.sh" jq-contract
    run_reader_test jq "$JQ_BIN" "$TEST_ROOT/tests/test_orca_mock.sh" jq-mock
else
    test_skip 'jq reader subprocess corpus' 'jq is not installed'
fi

# Selection and doctor checks use the current shell's isolated runtime.
export KEEPALIVE_ORCA_CLI="$TEST_ROOT/tests/fixtures/orca-mock" KEEPALIVE_ORCA_ENABLED=1
unset KEEPALIVE_ORCA_PARSER KEEPALIVE_JQ KEEPALIVE_AWK
KA_ORCA_CLI=''
if [[ -n $JQ_BIN ]]; then
    assert_true 'auto parser selects jq when jq is installed' ka_orca_find
    assert_eq jq "$KA_ORCA_PARSER" 'auto parser reports jq selection'
else
    test_skip 'auto parser prefers jq' 'jq is not installed'
fi
if [[ -n $SYSTEM_AWK ]]; then
    export KEEPALIVE_ORCA_PARSER=awk KEEPALIVE_AWK="$SYSTEM_AWK"
    KA_ORCA_CLI=''
    assert_true 'explicit awk parser selects the built-in reader' ka_orca_find
    assert_eq awk "$KA_ORCA_PARSER" 'explicit awk parser reports awk selection'
fi

invalid_jq="$TEST_TMP/not-an-executable-jq"
printf '#!/usr/bin/env bash\nexit 0\n' >"$invalid_jq"
chmod 600 "$invalid_jq"
export KEEPALIVE_ORCA_PARSER=auto KEEPALIVE_JQ="$invalid_jq"
KA_ORCA_CLI=''
assert_false 'an invalid explicit KEEPALIVE_JQ disables auto Orca' ka_orca_find
assert_eq '' "$KA_ORCA_CLI" 'invalid explicit KEEPALIVE_JQ leaves no Orca CLI selected'
invalid_awk="$TEST_TMP/not-an-executable-awk"
printf '#!/usr/bin/env bash\nexit 0\n' >"$invalid_awk"
chmod 600 "$invalid_awk"
export KEEPALIVE_ORCA_PARSER=awk KEEPALIVE_AWK="$invalid_awk"
KA_ORCA_CLI=''
assert_false 'an invalid explicit KEEPALIVE_AWK disables awk Orca' ka_orca_find
assert_eq '' "$KA_ORCA_CLI" 'invalid explicit KEEPALIVE_AWK leaves no Orca CLI selected'

no_jq_path="$TEST_TMP/no-jq-path"
build_no_jq_path "$no_jq_path"
no_jq_probe="$TEST_TMP/no-jq-selection-probe"
cat >"$no_jq_probe" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$TEST_ROOT/tests/testlib.sh"
test_env_setup
source_core
export KEEPALIVE_ORCA_ENABLED=1 KEEPALIVE_ORCA_CLI="$KEEPALIVE_ORCA_CLI" KEEPALIVE_ORCA_PARSER=auto
unset KEEPALIVE_JQ KEEPALIVE_AWK
if ka_orca_find; then printf '%s\n' "$KA_ORCA_PARSER"; else exit 1; fi
SH
chmod 700 "$no_jq_probe"
no_jq_selection="$TEST_TMP/no-jq-selection.out"
if run_no_jq_probe "$no_jq_probe" "$no_jq_path" "$no_jq_selection"; then
    assert_eq awk "$(<"$no_jq_selection")" 'auto parser falls back to awk when jq is absent'
else
    cat "$no_jq_selection"
    assert_true 'auto parser falls back to awk when jq is absent' false
fi

if [[ -n $SYSTEM_AWK ]]; then
    assert_doctor_reader awk "$SYSTEM_AWK" 'built-in awk reader'
fi
if [[ -n $JQ_BIN ]]; then
    assert_doctor_reader jq "$JQ_BIN" 'jq ('
fi

unset KEEPALIVE_JQ KEEPALIVE_AWK
export KEEPALIVE_ORCA_PARSER=bogus
KA_ORCA_CLI=''
assert_false 'an unknown KEEPALIVE_ORCA_PARSER disables Orca' ka_orca_find
assert_eq '' "$KA_ORCA_CLI" 'unknown parser leaves no Orca CLI selected'
invalid_parser_doctor="$TEST_TMP/doctor-invalid-parser.out"
invalid_parser_rc=0
env KEEPALIVE_KONSOLE_ENABLED=0 KEEPALIVE_ORCA_ENABLED=1 \
    KEEPALIVE_ORCA_CLI="$TEST_ROOT/tests/fixtures/orca-mock" KEEPALIVE_ORCA_PARSER=bogus \
    KEEPALIVE_JQ='' KEEPALIVE_AWK='' HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" \
    XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_STATE_HOME="$XDG_STATE_HOME" \
    "$TEST_ROOT/keepalive" doctor >"$invalid_parser_doctor" 2>&1 || invalid_parser_rc=$?
assert_true 'doctor remains diagnostic with an unknown parser' test "$invalid_parser_rc" -ge 0
assert_contains "$invalid_parser_doctor" 'MISSING (check KEEPALIVE_ORCA_PARSER' \
    'doctor reports the reader MISSING for an unknown parser'

missing_awk_copy="$TEST_TMP/lib-missing-awk"
mkdir -p "$missing_awk_copy"
cp -- "$TEST_ROOT/lib/orca.sh" "$missing_awk_copy/orca.sh"
missing_awk_probe="$TEST_TMP/missing-awk-probe"
cat >"$missing_awk_probe" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$TEST_ROOT/tests/testlib.sh"
test_env_setup
source_core
source "$MISSING_AWK_COPY/orca.sh"
export KEEPALIVE_ORCA_ENABLED=1 KEEPALIVE_ORCA_CLI="$KEEPALIVE_ORCA_CLI" KEEPALIVE_ORCA_PARSER=awk
if ka_orca_find; then exit 1; else exit 0; fi
SH
chmod 700 "$missing_awk_probe"
if env TEST_ROOT="$TEST_ROOT" MISSING_AWK_COPY="$missing_awk_copy" KEEPALIVE_ORCA_CLI="$KEEPALIVE_ORCA_CLI" \
    PATH="$PATH" bash "$missing_awk_probe"; then
    assert_true 'missing lib/orca.awk disables the awk path' true
else
    assert_true 'missing lib/orca.awk disables the awk path' false
fi

# Differential corpus. Raw-invalid-UTF8 is the only documented awk-only refusal boundary;
# every other envelope, including the jq 1.7 depth boundary, must have identical bytes
# and return statuses.
if command -v python3 >/dev/null 2>&1 && [[ -n $JQ_BIN && -n $SYSTEM_AWK ]]; then
    corpus="$TEST_TMP/corpus"
    build_corpus "$corpus"
    FAKE_ORCA_STUB="$TEST_TMP/corpus-cli"
    cat >"$FAKE_ORCA_STUB" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cat -- "$FAKE_ORCA_INPUT"
if [[ ${FAKE_ORCA_CLI_RC:-0} != 0 ]]; then exit "$FAKE_ORCA_CLI_RC"; fi
SH
    chmod 700 "$FAKE_ORCA_STUB"
    FAKE_ORCA_PROBE="$TEST_TMP/orca-probe"
    cat >"$FAKE_ORCA_PROBE" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
source "$TEST_ROOT/tests/testlib.sh"
test_env_setup
source_core
export KEEPALIVE_ORCA_ENABLED=1 KEEPALIVE_ORCA_CLI="$FAKE_ORCA_STUB" \
    KEEPALIVE_ORCA_PARSER="$PARSER_NAME" FAKE_ORCA_INPUT="$FAKE_ORCA_INPUT"
if [[ $PARSER_NAME == jq ]]; then export KEEPALIVE_JQ="$PARSER_BINARY"; else export KEEPALIVE_AWK="$PARSER_BINARY"; fi
KA_ORCA_CLI=''; KA_ORCA_JQ=''; KA_ORCA_AWK=''
ka_orca_find
operation=$1
case $operation in
    list) ka_orca_discover ;;
    show)
        if ka_orca_validate_target term-codex repo::/work/corpus@@pty-1 inc-corpus-1 \
            repo::/work/corpus runtime-corpus local tab-corpus-1 leaf-corpus-1 codex; then exit 0; else exit $?; fi
        ;;
    send)
        if ka_orca_deliver term-codex MESSAGE_ENTER ping 0; then exit 0; else exit $?; fi
        ;;
    status)
        if ka_orca_runtime_reachable; then exit 0; else exit $?; fi
        ;;
    error)
        json=$(cat -- "$FAKE_ORCA_INPUT")
        ka_orca_error_code "$json"
        printf '%s\n' "$REPLY"
        ;;
    *) exit 2 ;;
esac
SH
    chmod 700 "$FAKE_ORCA_PROBE"

    assert_probe_parity list "$corpus/list-valid.json" 'valid list corpus'
    assert_probe_parity list "$corpus/list-ptyless.json" 'pty-less list corpus'
    assert_probe_parity list "$corpus/list-collision.json" 'conflicting collision list corpus'
    assert_probe_parity list "$corpus/list-exact-duplicate.json" 'exact duplicate list corpus'
    assert_probe_parity list "$corpus/list-incomplete-duplicate.json" 'incomplete duplicate list corpus'
    for path in "$corpus"/list-unicode.json "$corpus"/list-controls.json "$corpus"/list-raw-utf8.json \
        "$corpus"/list-whitespace.json "$corpus"/list-number-*.json "$corpus"/list-empty.json; do
        assert_probe_parity list "$path" "list corpus $(basename "$path")"
    done
    for path in "$corpus"/envelope-*.json "$corpus"/list-100.json "$corpus"/list-1000.json \
        "$corpus"/list-1001.json "$corpus"/list-long-title.json; do
        assert_probe_parity list "$path" "envelope corpus $(basename "$path")"
    done
    assert_format_identity jq "$JQ_BIN" list "$corpus/list-valid.json" "$corpus/list-valid-pretty.json" \
        'compact and pretty list documents'
    assert_format_identity awk "$SYSTEM_AWK" list "$corpus/list-valid.json" "$corpus/list-valid-pretty.json" \
        'compact and pretty list documents'
    assert_probe_parity list "$corpus/list-multi-document.json" 'multi-document list corpus'
    assert_probe_parity list "$corpus/list-duplicate-keys.json" 'duplicate-key list corpus'
    assert_probe_parity show "$corpus/show-valid.json" 'valid show corpus'
    assert_probe_parity show "$corpus/show-no-pty.json" 'no-PTY show corpus'
    assert_probe_parity show "$corpus/show-no-agent.json" 'no-agent show corpus'
    assert_probe_parity show "$corpus/show-wrong-type.json" 'wrong-type show corpus'
    assert_probe_parity show "$corpus/show-multi-document.json" 'multi-document show corpus'
    assert_probe_parity send "$corpus/send-valid.json" 'valid send corpus'
    assert_probe_parity send "$corpus/send-rejected.json" 'rejected send corpus'
    assert_probe_parity send "$corpus/send-multi-document.json" 'multi-document send corpus'
    assert_probe_parity status "$corpus/status-reachable.json" 'reachable status corpus'
    assert_probe_parity status "$corpus/status-unreachable.json" 'unreachable status corpus'
    assert_probe_parity status "$corpus/status-multi-document.json" 'multi-document status corpus'
    assert_probe_parity error "$corpus/error-stale.json" 'stale error corpus'
    assert_probe_parity error "$corpus/error-unknown.json" 'unknown error corpus'
    assert_probe_parity error "$corpus/error-multi-document.json" 'multi-document error corpus'
    assert_probe_parity error "$corpus/malformed.json" 'malformed error corpus'
    for code in terminal_handle_stale terminal_gone selector_not_found \
        terminal_unsupported_for_agent_session terminal_surface_ownership_unavailable \
        runtime_unavailable unknown; do
        error_path="$corpus/show-error-$code.json"
        printf '%s\n' '{"ok":false,"error":{"code":"'"$code"'"},"_meta":{"runtimeId":null}}' >"$error_path"
        assert_probe_parity show "$error_path" "show error corpus $code" 1
    done
    for path in "$corpus"/deep-255.json "$corpus"/deep-256.json "$corpus"/deep-257.json; do
        assert_probe_parity list "$path" "deep corpus $(basename "$path")"
    done
    for path in "$corpus"/deep-row-array-*.json "$corpus"/deep-row-object-*.json; do
        assert_probe_parity list "$path" "nested unread member corpus $(basename "$path")"
    done
    assert_depth_boundary "$corpus/deep-row-array-248.json" 'nested array depth 248' complete
    for depth in 249 250 251 252 253 254 255 256; do
        assert_depth_boundary "$corpus/deep-row-array-$depth.json" "nested array depth $depth" refused
    done
    for depth in 122 123 124; do
        assert_depth_boundary "$corpus/deep-row-object-$depth.json" "nested object depth $depth" complete
    done
    for depth in 125 126 127 128; do
        assert_depth_boundary "$corpus/deep-row-object-$depth.json" "nested object depth $depth" refused
    done
    for operation in list show send status error; do
        assert_probe_parity "$operation" "$corpus/oversize.json" "oversize $operation corpus"
    done
    assert_awk_refusal list "$corpus/raw-invalid-utf8.json" 'raw invalid UTF-8 list'
else
    test_skip 'jq/awk differential corpus' 'jq, awk, and python3 are required'
fi

test_finish
