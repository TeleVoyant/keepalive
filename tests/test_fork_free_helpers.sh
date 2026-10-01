#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
source "$TEST_ROOT/lib/icons.sh"
source "$TEST_ROOT/lib/tui/screen.sh"
source "$TEST_ROOT/lib/tui/tui.sh"

declare -a TEST_STARTED_PIDS=()
# Role: Stop only the helper processes this test recorded and reap their statuses.
cleanup_started_processes() {
    local pid
    for pid in "${TEST_STARTED_PIDS[@]}"; do
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null || true
        fi
        wait "$pid" 2>/dev/null || true
    done
    TEST_STARTED_PIDS=()
}
trap cleanup_started_processes EXIT

# Role: Wait until a freshly exec'd probe exposes the expected argv[0] through procfs.
wait_for_proc_cmdline() {
    local pid=$1 expected=$2 first='' i
    for ((i = 0; i < 10000; i += 1)); do
        IFS= read -r -d '' first <"/proc/$pid/cmdline" 2>/dev/null || true
        [[ $first == "$expected" ]] && return 0
    done
    return 1
}

# Role: Launch a blocked Bash process whose procfs argv exercises empty, spaced, and newline arguments.
start_crafted_helper() {
    local fifo=$1 argv0=$2 script=$3 pid
    PROBE_FIFO=$fifo
    export PROBE_FIFO
    bash -c 'exec -a "$1" /bin/bash -c "$2" "$3" "" "trailing  " "$4"' \
        _ "$argv0" "$script" script-zero $'embedded\nnewline' &
    pid=$!
    TEST_STARTED_PIDS+=("$pid")
    wait_for_proc_cmdline "$pid" "$argv0"
    REPLY=$pid
}

# Role: Launch two same-argv, same-comm ELF copies so an in-place exec can probe cache invalidation.
start_exec_probe() {
    local fifo=$1 first_binary=$2 second_binary=$3 pid script
    script='exec 3<>"$PROBE_FIFO"; trap '\''exec -a "$0" "$NEXT_PROBE" -c "$PROBE_SCRIPT" "$0"'\'' USR1; while read -r -t 30 ignored <&3; do :; done'
    PROBE_FIFO=$fifo NEXT_PROBE=$second_binary PROBE_SCRIPT=$script
    export PROBE_FIFO NEXT_PROBE PROBE_SCRIPT
    bash -c 'exec -a "$1" "$2" -c "$3" "$1"' _ cache-probe "$first_binary" "$script" &
    pid=$!
    TEST_STARTED_PIDS+=("$pid")
    wait_for_proc_cmdline "$pid" cache-probe
    REPLY=$pid
}

# Role: Report whether a process-signature cache key is absent after a bounded reset.
cache_key_absent() {
    local key=$1
    [[ -z ${KA_PROC_EXE_FP[$key]+x} ]]
}

# Role: Count invocations recorded by a PATH shim without changing the shimmed command.
shim_count() {
    local path=$1
    [[ -r $path ]] || { printf '0'; return 0; }
    wc -l <"$path"
}

# Role: Convert the current TUI UUID array into a stable comma-separated comparison value.
tui_order_string() {
    local uuid output=''
    for uuid in "${KA_R_UUID[@]}"; do output+="$uuid,"; done
    printf '%s' "${output%,}"
}

# Role: Extract UUIDs from one fresh external TUI sort into REPLY for cache comparisons.
fresh_tui_order() {
    local rows=$1 sorted rest uuid output=''
    while IFS= read -r sorted; do
        rest=${sorted#*$'\t'}
        rest=${rest#*$'\t'}
        rest=${rest#*$'\t'}
        uuid=${rest%%$'\t'*}
        output+="$uuid," 
    done < <(printf '%s\n' "$rows" | ka_tui_sort_index_rows)
    REPLY=${output%,}
}

# Role: Write the mutable TUI row set and retain its exact source-order bytes for fresh sorting.
write_tui_index() {
    local path=$1
    printf '%s\n' "${INDEX_ROWS[@]}" >"$path"
    INDEX_CONTENT=$(printf '%s\n' "${INDEX_ROWS[@]}")
}

# Role: Assert that one malformed Orca list response is represented by the schema sentinel.
assert_orca_discovery_schema() {
    local path=$1 label=$2 output
    cp -- "$path" "$FAKE_ORCA_JSON_FILE"
    output=$(ka_orca_discover)
    assert_eq $'#INCOMPLETE\tschema' "$output" "$label"
}

# Role: Assert that one malformed Orca show response is rejected as indeterminate schema.
assert_orca_validation_schema() {
    local path=$1 label=$2 rc
    cp -- "$path" "$FAKE_ORCA_JSON_FILE"
    if ka_orca_validate_target "$ORCA_HANDLE" "$ORCA_PTY" "$ORCA_INCAR" \
        "$ORCA_WORKTREE" "$ORCA_RUNTIME" "$ORCA_HOST" "$ORCA_TAB" "$ORCA_LEAF" "$ORCA_AGENT"; then
        rc=0
    else
        rc=$?
    fi
    assert_eq 22 "$rc" "$label"
}

# --- /proc baseline semantics and REPLY/printing parity ---
ka_classifier_init
helper_fifo="$TEST_TMP/crafted-helper.fifo"
mkfifo "$helper_fifo"
helper_script='exec 3<>"$PROBE_FIFO"; trap '\''exit 0'\'' TERM INT; while read -r -t 30 ignored <&3; do :; done'
crafted_argv0='crafted-agent  '
start_crafted_helper "$helper_fifo" "$crafted_argv0" "$helper_script"
crafted_pid=$REPLY
expected_crafted_cmd=$(printf '%s -c %s script-zero  trailing   embedded\nnewline' \
    "$crafted_argv0" "$helper_script")

for proc_pid in "$$" "$crafted_pid"; do
    ka_proc_cmdline_set "$proc_pid"
    set_value=$REPLY
    print_value=$(ka_proc_cmdline "$proc_pid")
    assert_eq "$print_value" "$set_value" "cmdline _set agrees with printing wrapper for PID $proc_pid"

    ka_proc_comm_set "$proc_pid"
    set_value=$REPLY
    print_value=$(ka_proc_comm "$proc_pid")
    assert_eq "$print_value" "$set_value" "comm _set agrees with printing wrapper for PID $proc_pid"

    ka_proc_ppid_set "$proc_pid"
    set_value=$REPLY
    print_value=$(ka_proc_ppid "$proc_pid")
    assert_eq "$print_value" "$set_value" "PPID _set agrees with printing wrapper for PID $proc_pid"

    ka_proc_starttime_set "$proc_pid"
    set_value=$REPLY
    print_value=$(ka_proc_starttime "$proc_pid")
    assert_eq "$print_value" "$set_value" "starttime _set agrees with printing wrapper for PID $proc_pid"

    ka_proc_signature_set "$proc_pid"
    set_value=$REPLY
    print_value=$(ka_proc_signature "$proc_pid")
    assert_eq "$print_value" "$set_value" "signature _set agrees with printing wrapper for PID $proc_pid"
done

ka_proc_cmdline_set "$crafted_pid"
assert_eq "$expected_crafted_cmd" "$REPLY" \
    'cmdline _set preserves argv0, empty argument spacing, trailing spaces, and embedded newline semantics'
ka_proc_comm_set "$crafted_pid"
assert_eq bash "$REPLY" 'crafted helper comm uses the executable basename'
ka_proc_exe_basename "$crafted_pid" >"$TEST_TMP/crafted-exe"
assert_eq bash "$(<"$TEST_TMP/crafted-exe")" 'crafted helper executable basename is resolved through procfs'
ka_proc_ppid_set "$crafted_pid"
assert_eq "$$" "$REPLY" 'crafted helper PPID matches the launching test shell'
ka_proc_stat_field_set "$crafted_pid" 2
assert_eq "$REPLY" "$(ka_proc_ppid "$crafted_pid")" 'stat field 2 remains the PPID baseline field'
ka_proc_starttime_set "$crafted_pid"
assert_true 'crafted helper starttime is a numeric procfs tick value' grep -Eq '^[0-9]+$' <<<"$REPLY"
ka_proc_signature_set "$crafted_pid"
assert_eq 'bash bash crafted-agent   -c exec 3<>"$probe_fifo"; trap '\''exit 0'\'' term int; while read -r -t 30 ignored <&3; do :; done script-zero  trailing   embedded
newline' "$REPLY" \
    'signature lowercases comm, executable, and the baseline cmdline join'

ka_classifier_add 'Crafted' 'crafted-agent'
ka_classifier_match_pid_set "$crafted_pid"
set_value=$REPLY
print_value=$(ka_classifier_match_pid "$crafted_pid")
assert_eq "$print_value" "$set_value" 'classifier match _set agrees with printing wrapper'
assert_eq $'Crafted\t'"$crafted_pid" "$set_value" 'classifier match keeps the recognized name and PID'
ka_classifier_from_process_tree_set "$crafted_pid"
set_value=$REPLY
print_value=$(ka_classifier_from_process_tree "$crafted_pid")
assert_eq "$print_value" "$set_value" 'process-tree _set agrees with printing wrapper'
assert_eq $'Crafted\t'"$crafted_pid" "$set_value" 'process-tree classifier returns the nearest crafted process'

# --- executable cache hits, exec invalidation, and bound reset ---
readlink_shim_dir="$TEST_TMP/readlink-shim"
mkdir -p "$readlink_shim_dir"
readlink_count="$TEST_TMP/readlink.count"
cat >"$readlink_shim_dir/readlink" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$$" >>"$READLINK_COUNT"
exec /usr/bin/readlink "$@"
SHIM
chmod 700 "$readlink_shim_dir/readlink"
PATH="$readlink_shim_dir:$PATH"
export PATH READLINK_COUNT="$readlink_count"
: >"$readlink_count"
KA_PROC_EXE_FP=()
KA_PROC_EXE_PATH=()
ka_proc_signature_set "$crafted_pid"
first_signature=$REPLY
first_readlinks=$(shim_count "$readlink_count")
assert_eq 1 "$first_readlinks" 'first signature lookup resolves procfs executable once'
ka_proc_signature_set "$crafted_pid"
assert_eq "$first_signature" "$REPLY" 'cached signature remains byte-for-byte stable'
assert_eq "$first_readlinks" "$(shim_count "$readlink_count")" \
    'second signature lookup does not execute readlink again'

probe_a_dir="$TEST_TMP/probe-a"
probe_b_dir="$TEST_TMP/probe-b"
mkdir -p "$probe_a_dir" "$probe_b_dir"
cp -- /bin/bash "$probe_a_dir/probe"
cp -- /bin/bash "$probe_b_dir/probe"
exec_fifo="$TEST_TMP/exec-probe.fifo"
mkfifo "$exec_fifo"
start_exec_probe "$exec_fifo" "$probe_a_dir/probe" "$probe_b_dir/probe"
exec_probe_pid=$REPLY
ka_proc_starttime_set "$exec_probe_pid"
exec_cache_key="$exec_probe_pid:$REPLY"
ka_proc_signature_set "$exec_probe_pid"
exec_before=$REPLY
exec_before_count=$(shim_count "$readlink_count")
assert_eq "$probe_a_dir/probe" "${KA_PROC_EXE_PATH[$exec_cache_key]}" \
    'exec probe initially caches the first executable identity'
kill -USR1 "$exec_probe_pid"
exec_changed=0
for ((poll = 0; poll < 10000; poll += 1)); do
    if [[ /proc/$exec_probe_pid/exe -ef "$probe_b_dir/probe" ]]; then
        exec_changed=1
        break
    fi
done
assert_eq 1 "$exec_changed" 'same-argv same-comm probe successfully execs a different binary'
ka_proc_signature_set "$exec_probe_pid"
exec_after=$REPLY
exec_after_count=$(shim_count "$readlink_count")
assert_eq "$exec_before" "$exec_after" 'same-argv same-comm exec keeps the public signature stable'
assert_eq $((exec_before_count + 1)) "$exec_after_count" \
    'same-argv same-comm exec forces a cache miss and one fresh readlink'
assert_eq "$probe_b_dir/probe" "${KA_PROC_EXE_PATH[$exec_cache_key]}" \
    'cache replacement records the post-exec executable path'

KA_PROC_EXE_CACHE_MAX=2
KA_PROC_EXE_FP=()
KA_PROC_EXE_PATH=()
ka_proc_starttime_set "$$"
cache_self_key="$$:$REPLY"
ka_proc_starttime_set "$crafted_pid"
cache_crafted_key="$crafted_pid:$REPLY"
ka_proc_starttime_set "$exec_probe_pid"
cache_exec_key="$exec_probe_pid:$REPLY"
ka_proc_signature_set "$$"
ka_proc_signature_set "$crafted_pid"
assert_eq 2 "${#KA_PROC_EXE_FP[@]}" 'executable cache holds two entries before its bound is reached'
ka_proc_signature_set "$exec_probe_pid"
assert_eq 1 "${#KA_PROC_EXE_FP[@]}" 'executable cache resets wholesale at KA_PROC_EXE_CACHE_MAX'
assert_true 'cache bound reset evicts the oldest process key' cache_key_absent "$cache_self_key"
assert_true 'cache bound reset evicts the earlier crafted-process key' cache_key_absent "$cache_crafted_key"
assert_true 'cache bound reset retains the newest process key' test -n "${KA_PROC_EXE_FP[$cache_exec_key]+present}"
KA_PROC_EXE_CACHE_MAX=1024
KA_PROC_EXE_FP=()
KA_PROC_EXE_PATH=()
PATH=${PATH#"$readlink_shim_dir:"}
export PATH

# --- caller-shell discovery keeps classifier cache entries across state refresh ---
source "$TEST_ROOT/lib/qdbus.sh"
export KEEPALIVE_QDBUS="$TEST_ROOT/tests/fixtures/qdbus-mock"
export FAKE_PID=$$
KA_QDBUS=''
ka_qdbus_find
ka_classifier_add 'Test discovery' 'test_fork_free_helpers'
ka_state_init_arrays
ka_proc_starttime_set "$$"
discovery_cache_key="$$:$REPLY"
ka_konsole_discover_rows
assert_eq '#COMPLETE' "${KA_DISCOVERY_ROWS[${#KA_DISCOVERY_ROWS[@]} - 1]}" \
    'Konsole discovery rows complete in the caller shell'
assert_true 'direct Konsole discovery leaves the process executable cache populated' \
    test -n "${KA_PROC_EXE_FP[$discovery_cache_key]+present}"
cache_entries_before=${#KA_PROC_EXE_FP[@]}
assert_true 'state refresh accepts the qdbus mock discovery pass' ka_state_refresh_konsole_discovery
assert_eq "$cache_entries_before" "${#KA_PROC_EXE_FP[@]}" \
    'state refresh preserves caller-shell executable cache entries'
assert_true 'state refresh still retains the discovered process cache key' \
    test -n "${KA_PROC_EXE_FP[$discovery_cache_key]+present}"

# --- D-Bus array/line parsing and ordered nested introspection nodes ---
source "$TEST_ROOT/lib/qdbus.sh"

# Role: Supply deterministic dbus-send-style scalar output to the parser under test.
ka_dbus_send_scalar() {
    printf '%s' "$MOCK_DBUS_SCALAR"
}

# Role: Supply deterministic qdbus line output to the parser under test.
ka_qdbus_exec() {
    printf '%s\n' "$MOCK_QDBUS_LINES"
}

unset KEEPALIVE_QDBUS
KA_DBUS_SEND=mock-dbus-send
MOCK_DBUS_SCALAR='org.freedesktop.DBus org.kde.konsole org.kde.konsole-9 xorg.kde.konsole-9'
assert_eq $'org.kde.konsole\norg.kde.konsole-9\norg.kde.konsole-9' \
    "$(ka_qdbus_konsole_services)" \
    'dbus-send array parsing preserves old grep -o token and xorg-prefix behavior'
MOCK_DBUS_SCALAR='<node name="9"><node name="2"/><node name="17"/></node><node name="text"/><node name="4"/>'
assert_eq $'/Sessions/9\n/Sessions/2\n/Sessions/17\n/Sessions/4' \
    "$(ka_konsole_session_paths org.kde.konsole)" \
    'dbus-send introspection parsing preserves nested node order and ignores nonnumeric nodes'

KEEPALIVE_QDBUS=mock-qdbus
KA_DBUS_SEND=''
MOCK_QDBUS_LINES=$'org.kde.konsole\norg.kde.konsole-9\nxorg.kde.konsole-9\norg.kde.konsole suffix'
assert_eq $'org.kde.konsole\norg.kde.konsole-9\norg.kde.konsole-9' \
    "$(ka_qdbus_konsole_services)" \
    'qdbus line parsing rejects a suffixed line and retains old grep -o xorg token behavior'

# --- Orca jq fail-closed corpus ---
if ! command -v jq >/dev/null 2>&1; then
    test_skip 'Orca malformed-stream assertions' 'jq is not installed'
else
    orca_stub="$TEST_TMP/orca-json-stub"
    cat >"$orca_stub" <<'SHIM'
#!/usr/bin/env bash
set -Eeuo pipefail
cat -- "$FAKE_ORCA_JSON_FILE"
SHIM
    chmod 700 "$orca_stub"
    valid_list="$TEST_TMP/orca-valid-list.json"
    valid_show="$TEST_TMP/orca-valid-show.json"
    cat >"$valid_list" <<'JSON'
{"ok":true,"result":{"terminals":[{"handle":"term-agent","ptyId":"pty-1","incarnationId":"inc-1","worktreeId":"wt-1","worktreePath":"/work/agent","title":"Agent","connected":true,"writable":true,"orphaned":false,"executionHostId":"host-1","tabId":"tab-1","leafId":"leaf-1","agentIdentity":"codex"}],"truncated":false},"_meta":{"runtimeId":"runtime-1"}}
JSON
    cat >"$valid_show" <<'JSON'
{"ok":true,"result":{"terminal":{"handle":"term-agent","ptyId":"pty-1","incarnationId":"inc-1","worktreeId":"wt-1","worktreePath":"/work/agent","connected":true,"writable":true,"orphaned":false,"executionHostId":"host-1","tabId":"tab-1","leafId":"leaf-1","agentIdentity":"codex"}},"_meta":{"runtimeId":"runtime-1"}}
JSON
    export KEEPALIVE_ORCA_ENABLED=1 KEEPALIVE_ORCA_CLI="$orca_stub" KEEPALIVE_JQ="$(command -v jq)"
    export FAKE_ORCA_JSON_FILE="$TEST_TMP/orca-selected.json" KEEPALIVE_ORCA_TIMEOUT=3
    KA_ORCA_CLI=''
    KA_ORCA_JQ=''
    assert_true 'Orca JSON-file stub resolves as the explicit adapter CLI' ka_orca_find
    cp -- "$valid_list" "$FAKE_ORCA_JSON_FILE"
    valid_discovery_output="$TEST_TMP/orca-valid-discovery.out"
    ka_orca_discover >"$valid_discovery_output"
    assert_contains "$valid_discovery_output" $'#COMPLETE' \
        'valid Orca list JSON reaches the complete discovery marker'
    cp -- "$valid_show" "$FAKE_ORCA_JSON_FILE"
    ORCA_HANDLE=term-agent ORCA_PTY=pty-1 ORCA_INCAR=inc-1 ORCA_WORKTREE=wt-1 \
        ORCA_RUNTIME=runtime-1 ORCA_HOST=host-1 ORCA_TAB=tab-1 ORCA_LEAF=leaf-1 ORCA_AGENT=codex
    assert_true 'valid Orca show JSON remains accepted by the fail-closed parser' \
        ka_orca_validate_target "$ORCA_HANDLE" "$ORCA_PTY" "$ORCA_INCAR" "$ORCA_WORKTREE" \
        "$ORCA_RUNTIME" "$ORCA_HOST" "$ORCA_TAB" "$ORCA_LEAF" "$ORCA_AGENT"

    multi_valid_invalid_list="$TEST_TMP/orca-valid-invalid-list.json"
    multi_invalid_valid_list="$TEST_TMP/orca-invalid-valid-list.json"
    multi_valid_invalid_show="$TEST_TMP/orca-valid-invalid-show.json"
    multi_invalid_valid_show="$TEST_TMP/orca-invalid-valid-show.json"
    { cat "$valid_list"; printf '{"broken":\n'; } >"$multi_valid_invalid_list"
    { printf '{"broken":\n'; cat "$valid_list"; } >"$multi_invalid_valid_list"
    { cat "$valid_show"; printf '{"broken":\n'; } >"$multi_valid_invalid_show"
    { printf '{"broken":\n'; cat "$valid_show"; } >"$multi_invalid_valid_show"
    assert_orca_discovery_schema "$multi_valid_invalid_list" \
        'Orca discovery rejects a valid document followed by an invalid document'
    assert_orca_discovery_schema "$multi_invalid_valid_list" \
        'Orca discovery rejects an invalid document followed by a valid document'
    assert_orca_validation_schema "$multi_valid_invalid_show" \
        'Orca validation rejects a valid document followed by an invalid document'
    assert_orca_validation_schema "$multi_invalid_valid_show" \
        'Orca validation rejects an invalid document followed by a valid document'

    non_object_list="$TEST_TMP/orca-non-object-list.json"
    non_object_show="$TEST_TMP/orca-non-object-show.json"
    printf '[]\n' >"$non_object_list"
    printf '[]\n' >"$non_object_show"
    assert_orca_discovery_schema "$non_object_list" 'Orca discovery rejects non-object JSON'
    assert_orca_validation_schema "$non_object_show" 'Orca validation rejects non-object JSON'

    unparseable_list="$TEST_TMP/orca-unparseable-list.json"
    unparseable_show="$TEST_TMP/orca-unparseable-show.json"
    printf '{not-json\n' >"$unparseable_list"
    printf '{not-json\n' >"$unparseable_show"
    assert_orca_discovery_schema "$unparseable_list" 'Orca discovery rejects unparseable JSON'
    assert_orca_validation_schema "$unparseable_show" 'Orca validation rejects unparseable JSON'

    for missing_list_field in handle ptyId incarnationId worktreeId worktreePath executionHostId tabId leafId; do
        missing_list="$TEST_TMP/orca-missing-list-$missing_list_field.json"
        jq --arg field "$missing_list_field" 'del(.result.terminals[0][$field])' \
            "$valid_list" >"$missing_list"
        assert_orca_discovery_schema "$missing_list" \
            "Orca discovery rejects an agent row missing $missing_list_field"
    done
    missing_agent_identity="$TEST_TMP/orca-missing-list-agentIdentity.json"
    jq 'del(.result.terminals[0].agentIdentity)' "$valid_list" >"$missing_agent_identity"
    cp -- "$missing_agent_identity" "$FAKE_ORCA_JSON_FILE"
    missing_agent_output="$TEST_TMP/orca-missing-agent.out"
    ka_orca_discover >"$missing_agent_output"
    assert_eq '#COMPLETE' "$(<"$missing_agent_output")" \
        'Orca discovery skips ordinary shell rows missing optional agentIdentity'
    wrong_agent_identity="$TEST_TMP/orca-wrong-list-agentIdentity.json"
    jq '.result.terminals[0].agentIdentity = {}' "$valid_list" >"$wrong_agent_identity"
    assert_orca_discovery_schema "$wrong_agent_identity" \
        'Orca discovery rejects an agent row with wrong-typed agentIdentity'
    missing_list="$TEST_TMP/orca-missing-list-runtimeId.json"
    jq 'del(._meta.runtimeId)' "$valid_list" >"$missing_list"
    assert_orca_discovery_schema "$missing_list" \
        'Orca discovery rejects a response missing _meta.runtimeId'

    for missing_show_field in handle ptyId incarnationId worktreeId executionHostId tabId leafId agentIdentity; do
        missing_show="$TEST_TMP/orca-missing-show-$missing_show_field.json"
        jq --arg field "$missing_show_field" 'del(.result.terminal[$field])' \
            "$valid_show" >"$missing_show"
        assert_orca_validation_schema "$missing_show" \
            "Orca validation returns 22 when show is missing $missing_show_field"
    done
    missing_show="$TEST_TMP/orca-missing-show-runtimeId.json"
    jq 'del(._meta.runtimeId)' "$valid_show" >"$missing_show"
    assert_orca_validation_schema "$missing_show" \
        'Orca validation returns 22 when show is missing _meta.runtimeId'
fi

# --- TUI REPLY render helpers and per-UUID sort cache ---
KA_ASCII_MODE=0
KA_ICONS_ENABLED=0
KA_COLOR_ENABLED=0
ka_icons_init
ka_tui_style_init
ka_tui_truncate_set 'abcdef' 4
ascii_set=$REPLY
ascii_print=$(ka_tui_truncate 'abcdef' 4)
assert_eq "$ascii_print" "$ascii_set" 'ASCII truncate _set agrees with printing wrapper'
assert_eq 'abc…' "$ascii_set" 'ASCII truncation uses character budget and ellipsis'
ka_tui_truncate_set 'éclair' 2
assert_eq $'é…' "$REPLY" 'multibyte truncation cuts on characters without broken UTF-8'
ka_tui_truncate_set '界面名' 2
assert_eq $'界…' "$REPLY" 'CJK truncation returns whole UTF-8 characters'
for duration in 0 59 60 3661; do
    ka_format_duration_set "$duration"
    set_value=$REPLY
    print_value=$(ka_format_duration "$duration")
    assert_eq "$print_value" "$set_value" "duration _set agrees with printing wrapper for $duration seconds"
done

sort_shim_dir="$TEST_TMP/sort-shim"
mkdir -p "$sort_shim_dir"
sort_count_file="$TEST_TMP/sort.count"
real_sort=$(command -v sort)
cat >"$sort_shim_dir/sort" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$$" >>"$SORT_COUNT_FILE"
exec "$REAL_SORT" "$@"
SHIM
chmod 700 "$sort_shim_dir/sort"
PATH="$sort_shim_dir:$PATH"
REAL_SORT=$real_sort
export PATH SORT_COUNT_FILE="$sort_count_file" REAL_SORT
: >"$sort_count_file"
KA_INDEX_FILE="$TEST_TMP/index.tsv"
base_u1=$'u1\tClaude\tAlpha\t/work/a\tACTIVE\t120\t300\t1\t60\t600\tMESSAGE_ENTER\t0\t-\t\tkonsole'
base_u2=$'u2\tCodex\tBeta\t/work/b\tPAUSED\t220\t300\t1\t60\t600\tMESSAGE_ENTER\t0\t-\t\tkonsole'
base_u3=$'u3\tKimi\tGamma\t/work/c\tAVAILABLE\t0\t300\t0\t0\t600\tENTER_ONLY\t0\t-\t\tkonsole'
INDEX_ROWS=("$base_u2" "$base_u3" "$base_u1")
write_tui_index "$KA_INDEX_FILE"
fresh_tui_order "$INDEX_CONTENT"
initial_expected=$REPLY
: >"$sort_count_file"
ka_tui_load_index
initial_actual=$(tui_order_string)
assert_eq "$initial_expected" "$initial_actual" 'initial TUI order equals a fresh sort of the row set'
assert_eq 1 "$(shim_count "$sort_count_file")" 'initial TUI load invokes external sort once'

# Timer-only edits must not invalidate the per-UUID type/name/status key map.
timer_u1=$'u1\tClaude\tAlpha\t/work/a\tACTIVE\t1\t300\t1\t2\t600\tMESSAGE_ENTER\t0\t-\t\tkonsole'
timer_u2=$'u2\tCodex\tBeta\t/work/b\tPAUSED\t2\t300\t1\t3\t600\tMESSAGE_ENTER\t0\t-\t\tkonsole'
timer_u3=$'u3\tKimi\tGamma\t/work/c\tAVAILABLE\t0\t300\t0\t0\t600\tENTER_ONLY\t0\t-\t\tkonsole'
INDEX_ROWS=("$timer_u3" "$timer_u1" "$timer_u2")
write_tui_index "$KA_INDEX_FILE"
: >"$sort_count_file"
ka_tui_load_index
assert_eq 0 "$(shim_count "$sort_count_file")" 'timer-only row changes skip external sort'
assert_eq "$initial_actual" "$(tui_order_string)" 'timer-only row changes preserve cached order'

# Reordering source rows without changing their keys must also skip external sort.
INDEX_ROWS=("$timer_u2" "$timer_u1" "$timer_u3")
write_tui_index "$KA_INDEX_FILE"
: >"$sort_count_file"
ka_tui_load_index
assert_eq 0 "$(shim_count "$sort_count_file")" 'reordered rows with identical keys skip external sort'
assert_eq "$initial_actual" "$(tui_order_string)" 'reordered rows retain the cached sorted order'

# Role: Load one changed row set, compare its order to a fresh sort, and count one cache miss.
load_changed_tui_index() {
    local label=$1 expected
    fresh_tui_order "$INDEX_CONTENT"
    expected=$REPLY
    : >"$sort_count_file"
    ka_tui_load_index
    assert_eq "$expected" "$(tui_order_string)" "$label order equals a fresh sort"
    assert_eq 1 "$(shim_count "$sort_count_file")" "$label invokes external sort after key/set change"
}

changed_type=$'u3\tClaude\tGamma\t/work/c\tAVAILABLE\t0\t300\t0\t0\t600\tENTER_ONLY\t0\t-\t\tkonsole'
INDEX_ROWS=("$timer_u2" "$timer_u1" "$changed_type")
write_tui_index "$KA_INDEX_FILE"
load_changed_tui_index 'type change'
changed_name=$'u1\tClaude\tZulu\t/work/a\tACTIVE\t1\t300\t1\t2\t600\tMESSAGE_ENTER\t0\t-\t\tkonsole'
INDEX_ROWS=("$timer_u2" "$changed_name" "$changed_type")
write_tui_index "$KA_INDEX_FILE"
load_changed_tui_index 'name change'
changed_status=$'u2\tCodex\tBeta\t/work/b\tACTIVE\t2\t300\t1\t3\t600\tMESSAGE_ENTER\t0\t-\tkonsole'
INDEX_ROWS=("$changed_status" "$changed_name" "$changed_type")
write_tui_index "$KA_INDEX_FILE"
load_changed_tui_index 'status change'

added_u4=$'u4\tAider\tDelta\t/work/d\tAVAILABLE\t0\t300\t0\t0\t600\tMESSAGE_ENTER\t0\t-\t\tkonsole'
INDEX_ROWS=("$added_u4" "$changed_status" "$changed_name" "$changed_type")
write_tui_index "$KA_INDEX_FILE"
load_changed_tui_index 'row-set addition'

cleanup_started_processes

# Restore the caller's command lookup path before the EXIT cleanup and test summary.
PATH=${PATH#"$sort_shim_dir:"}
export PATH

test_finish
