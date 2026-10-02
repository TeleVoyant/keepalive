#!/usr/bin/env bash
# Output encoders, terminal-boundary validation, and CLI presentation safety.
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
source "$TEST_ROOT/keepalive" --version >/dev/null

# Role: Render arbitrary bytes as a compact hexadecimal string for byte-exact assertions.
hex_of() {
    local value=${1-}
    printf '%s' "$value" | od -An -v -tx1 | tr -d ' \n'
}

# Role: Run the human sanitizer in the current shell and print its result for capture.
sanitary_text() {
    ka_sanitize_human_set "${1-}"
    printf '%s' "$REPLY"
}

# Role: Check whether an associative sanitizer-cache key is present without expanding it.
cache_has_key() {
    local key=$1
    [[ ${KA_SANITIZE_CACHE["$key"]+x} == x ]]
}

# Role: Sanitize one value under a requested locale and return its bytes as hex.
sanitary_hex_in_locale() {
    local locale=$1 value=${2-}
    local LC_ALL=$locale
    ka_sanitize_human_set "$value"
    hex_of "$REPLY"
}

# Role: Validate a byte string as structurally valid UTF-8 without iconv or external state.
utf8_valid_bytes() {
    local LC_ALL=C
    local value index length
    value=${1-}
    index=0
    length=${#value}
    local byte second third fourth lead second_ord third_ord fourth_ord
    while ((index < length)); do
        byte=${value:index:1}
        printf -v lead '%d' "'$byte"
        lead=$((lead & 255))
        if ((lead < 128)); then
            ((index += 1))
            continue
        fi
        if ((lead >= 194 && lead <= 223)); then
            ((index + 1 < length)) || return 1
            second=${value:index + 1:1}
            printf -v second_ord '%d' "'$second"
            second_ord=$((second_ord & 255))
            ((second_ord >= 128 && second_ord <= 191)) || return 1
            ((index += 2))
            continue
        fi
        if ((lead >= 224 && lead <= 239)); then
            ((index + 2 < length)) || return 1
            second=${value:index + 1:1}; third=${value:index + 2:1}
            printf -v second_ord '%d' "'$second"
            second_ord=$((second_ord & 255))
            printf -v third_ord '%d' "'$third"
            third_ord=$((third_ord & 255))
            ((third_ord >= 128 && third_ord <= 191)) || return 1
            if ((lead == 224)); then
                ((second_ord >= 160 && second_ord <= 191)) || return 1
            elif ((lead == 237)); then
                ((second_ord >= 128 && second_ord <= 159)) || return 1
            else
                ((second_ord >= 128 && second_ord <= 191)) || return 1
            fi
            ((index += 3))
            continue
        fi
        if ((lead >= 240 && lead <= 244)); then
            ((index + 3 < length)) || return 1
            second=${value:index + 1:1}; third=${value:index + 2:1}; fourth=${value:index + 3:1}
            printf -v second_ord '%d' "'$second"
            second_ord=$((second_ord & 255))
            printf -v third_ord '%d' "'$third"
            third_ord=$((third_ord & 255))
            printf -v fourth_ord '%d' "'$fourth"
            fourth_ord=$((fourth_ord & 255))
            ((third_ord >= 128 && third_ord <= 191)) || return 1
            ((fourth_ord >= 128 && fourth_ord <= 191)) || return 1
            if ((lead == 240)); then
                ((second_ord >= 144 && second_ord <= 191)) || return 1
            elif ((lead == 244)); then
                ((second_ord >= 128 && second_ord <= 143)) || return 1
            else
                ((second_ord >= 128 && second_ord <= 191)) || return 1
            fi
            ((index += 4))
            continue
        fi
        return 1
    done
    return 0
}

# Role: Truncate one value in an isolated locale and print the resulting bytes as hex.
truncate_hex_in_locale() {
    local locale=$1 value=${2-} width=$3
    unset KA_TUI_BYTE_LOCALE
    LC_ALL=$locale ka_tui_truncate_set "$value" "$width"
    hex_of "$REPLY"
}

# Role: Return the status and request-reach flag for one empty-UUID public CLI form.
empty_uuid_probe() {
    local rc=0
    CLI_REQUEST_REACHED=0
    ka_cli_main "$@" >/dev/null 2>"$TEST_TMP/empty-uuid.err" || rc=$?
    printf '%s\t%s' "$rc" "$CLI_REQUEST_REACHED"
}

# Role: Return a CLI log-reader status while preserving its diagnostic for assertions.
logs_probe() {
    local uuid=$1 rc=0
    ka_cli_logs "$uuid" >"$TEST_TMP/logs.out" 2>"$TEST_TMP/logs.err" || rc=$?
    printf '%s' "$rc"
}

# Role: Check that a captured string contains no terminal Escape or BEL byte.
no_terminal_controls() {
    local value=${1-}
    [[ $value != *$'\033'* && $value != *$'\a'* ]]
}

# Role: Validate one JSON document through jq without printing its parsed value.
json_document_valid() {
    jq -e . >/dev/null 2>&1 <<<"$1"
}

# Role: Return the validation status for the current mutable Orca show fixture.
orca_show_probe() {
    local rc=0
    ka_orca_validate_target term-agent pty-1 inc-1 wt-1 runtime-1 host-1 tab-1 leaf-1 codex || rc=$?
    printf '%s' "$rc"
}

# Role: Make the request path observable while empty UUID dispatch is being tested.
ka_cli_request() {
    CLI_REQUEST_REACHED=1
    return 0
}

# Role: Make create dispatch observable while empty UUID validation is being tested.
ka_cli_create() {
    CLI_REQUEST_REACHED=1
    return 0
}

# Role: Make configure dispatch observable while empty UUID validation is being tested.
ka_cli_configure() {
    CLI_REQUEST_REACHED=1
    return 0
}

# Role: Make pause/resume dispatch observable while empty UUID validation is being tested.
ka_cli_set_paused() {
    CLI_REQUEST_REACHED=1
    return 0
}

# --- Human sanitizer: controls, Unicode validity, cache, and locale invariance. ---
unsafe_human=$'left\x01\x02\x07\t\n\r\033]52;c;payload\a\x1f\x7f\x80\x9fright'
assert_eq 'left   ]52;c;payloadright' "$(sanitary_text "$unsafe_human")" \
    'human sanitizer removes C0/ESC/OSC/BEL, DEL, and raw C1 while spacing tab/newline/CR'

utf8_controls=$'pre\xc2\x80\xc2\x9f\xe2\x80\xaa\xe2\x80\xae\xe2\x81\xa6\xe2\x81\xa9post'
assert_eq prepost "$(sanitary_text "$utf8_controls")" \
    'human sanitizer removes UTF-8 C1 bytes and bidi overrides/isolate marks'

valid_utf8=$'\xc3\xa9\xc4\x80\xe2\x82\xac\xf0\x9f\x98\x80'
assert_eq c3a9c480e282acf09f9880 "$(hex_of "$(sanitary_text "$valid_utf8")")" \
    'human sanitizer preserves valid 2/3/4-byte UTF-8 byte-for-byte'

assert_eq '' "$(sanitary_text '')" 'human sanitizer preserves the empty string'
assert_eq 41efbfbd5a "$(hex_of "$(sanitary_text $'A\xffZ')")" \
    'human sanitizer replaces a malformed high byte with U+FFFD'
assert_eq 41efbfbd415a "$(hex_of "$(sanitary_text $'A\xc3AZ')")" \
    'human sanitizer replaces a truncated UTF-8 lead byte with U+FFFD'

KA_SANITIZE_CACHE=()
KA_SANITIZE_CACHE_MAX=256
cache_input=$'cache] * @ "\xc3\xa9'
ka_sanitize_human_set "$cache_input"
cache_first=$REPLY
assert_true 'non-ASCII sanitizer result is cached under its exact key' cache_has_key "$cache_input"
assert_eq 1 "${#KA_SANITIZE_CACHE[@]}" 'first non-ASCII sanitizer call creates one cache entry'
KA_SANITIZE_CACHE["$cache_input"]='cache-hit-marker'
ka_sanitize_human_set "$cache_input"
assert_eq cache-hit-marker "$REPLY" 'repeated non-ASCII sanitizer input hits the cache'
assert_eq cache-hit-marker "${KA_SANITIZE_CACHE["$cache_input"]}" \
    'cache retains keys containing ] * @ and quotes without re-parsing them'
assert_eq "$cache_input" "$cache_first" 'cache probe initially stored the exact special-character input'

for special in ']' '*' '@' '"'; do
    special_key="special${special}é"
    ka_sanitize_human_set "$special_key"
    assert_true "sanitizer caches key containing $special" cache_has_key "$special_key"
done

KA_SANITIZE_CACHE=()
KA_SANITIZE_CACHE_MAX=2
ka_sanitize_human_set $'cache-one-é'
ka_sanitize_human_set $'cache-two-é'
assert_eq 2 "${#KA_SANITIZE_CACHE[@]}" 'sanitizer cache reaches its configured maximum'
ka_sanitize_human_set $'cache-three-é'
assert_eq 1 "${#KA_SANITIZE_CACHE[@]}" 'sanitizer cache clears wholesale at its maximum'
assert_true 'cache keeps the newest value after wholesale eviction' cache_has_key $'cache-three-é'
assert_false 'cache evicts the oldest value after wholesale eviction' cache_has_key $'cache-one-é'
KA_SANITIZE_CACHE_MAX=256

locale_value=$'é/漢字/😀'
utf8_locale=''
while IFS= read -r locale_name; do
    case ${locale_name,,} in
        *utf8*|*utf-8*) utf8_locale=$locale_name; break ;;
    esac
done < <(locale -a 2>/dev/null || true)
if [[ -n $utf8_locale ]]; then
    c_locale_hex=$(sanitary_hex_in_locale C "$locale_value")
    utf8_locale_hex=$(sanitary_hex_in_locale "$utf8_locale" "$locale_value")
    assert_eq "$c_locale_hex" "$utf8_locale_hex" \
        'human sanitizer gives identical valid UTF-8 bytes in C and UTF-8 locales'
else
    test_skip 'human sanitizer locale invariance' 'no UTF-8 locale is installed'
fi

# --- JSON and D-Bus escaping. ---
json_two_slashes=$'\\\\'
assert_eq '\b' "$(ka_json_escape $'\b')" 'JSON escape emits one named backspace escape'
assert_eq '\t' "$(ka_json_escape $'\t')" 'JSON escape emits one named tab escape'
assert_eq '\n' "$(ka_json_escape $'\n')" 'JSON escape emits one named newline escape'
assert_eq '\f' "$(ka_json_escape $'\f')" 'JSON escape emits one named form-feed escape'
assert_eq '\r' "$(ka_json_escape $'\r')" 'JSON escape emits one named carriage-return escape'
assert_eq "$json_two_slashes" "$(ka_json_escape $'\\')" 'JSON escape doubles a literal backslash'
assert_eq '\"' "$(ka_json_escape '"')" 'JSON escape quotes a literal double quote'
assert_eq '\u0001' "$(ka_json_escape $'\x01')" 'JSON escape uses a Unicode escape for other C0 bytes'
assert_eq '\u007f' "$(ka_json_escape $'\x7f')" 'JSON escape uses a Unicode escape for DEL'
assert_eq '\u0080' "$(ka_json_escape $'\x80')" 'JSON escape uses a Unicode escape for raw C1 bytes'
assert_eq '\u00ff' "$(ka_json_escape $'\xff')" 'JSON escape uses a Unicode escape for malformed high bytes'
assert_eq c3a9 "$(hex_of "$(ka_json_escape 'é')")" 'JSON escape preserves valid UTF-8 bytes'

json_input=$'A\b\t\n\f\r\\"\x01\x7f\x80\xff\xc3\xa9'
json_encoded=$(ka_json_escape "$json_input")
if command -v jq >/dev/null 2>&1; then
    json_document=$(printf '"%s"' "$json_encoded")
    assert_true 'JSON escaped output parses as one jq string' json_document_valid "$json_document"
    json_decoded=$(jq -j . <<<"$json_document")
    json_expected=$'A\b\t\n\f\r\\"\x01\x7f\xc2\x80\xc3\xbf\xc3\xa9'
    assert_eq "$(hex_of "$json_expected")" "$(hex_of "$json_decoded")" \
        'JSON escaped controls, C1, malformed bytes, and valid UTF-8 round-trip through jq'
else
    test_skip 'JSON jq round-trip' 'jq is not installed'
fi

dbus_value=$'/tmp/é/\xff'
ka_dbus_escape_address_value "$dbus_value"
assert_eq '/tmp/%C3%A9/%FF' "$REPLY" 'D-Bus address escaping percent-encodes UTF-8 bytes'

# --- Locale-safe TUI truncation. ---
source "$TEST_ROOT/lib/icons.sh"
source "$TEST_ROOT/lib/tui/screen.sh"
KA_ASCII_MODE=0
KA_ICONS_ENABLED=0
ka_icons_init
ka_tui_style_init

for trunc_case in e-accent cjk emoji; do
    case $trunc_case in
        e-accent) trunc_value='éabc'; trunc_width=4 ;;
        cjk) trunc_value='漢字abc'; trunc_width=3 ;;
        emoji) trunc_value='😀abc'; trunc_width=3 ;;
    esac
    trunc_result=$(truncate_hex_in_locale C "$trunc_value" "$trunc_width")
    assert_true "C-locale $trunc_case truncation remains valid UTF-8" utf8_valid_bytes "$(printf '%b' "$(printf '%s' "$trunc_result" | sed 's/../\\x&/g')")"
done

# The Bash validator above consumes bytes; also pin the exact C-locale outputs for the
# boundary cases that formerly returned a lone lead byte.
assert_eq c3a961 "$(truncate_hex_in_locale C 'éabc' 3)" \
    'C-locale truncation keeps a complete multibyte prefix when it fits'
assert_eq e280a6 "$(truncate_hex_in_locale C 'éabc' 4)" \
    'C-locale truncation drops a partial prefix before appending the ellipsis'

if [[ -n $utf8_locale ]]; then
    assert_eq c3a9 "$(truncate_hex_in_locale "$utf8_locale" 'é' 1)" \
        'UTF-8 truncation preserves an exact-fit accented character'
    assert_eq c3a9e280a6 "$(truncate_hex_in_locale "$utf8_locale" 'éabc' 2)" \
        'UTF-8 truncation preserves accented text and its ellipsis budget'
    assert_eq e6bca2e280a6 "$(truncate_hex_in_locale "$utf8_locale" '漢字abc' 2)" \
        'UTF-8 truncation preserves a CJK character boundary'
    assert_eq f09f9880e280a6 "$(truncate_hex_in_locale "$utf8_locale" '😀abc' 2)" \
        'UTF-8 truncation preserves an emoji character boundary'
else
    test_skip 'UTF-8 TUI truncation cases' 'no UTF-8 locale is installed'
fi

# --- CLI output and empty UUID boundaries. ---
# Role: Keep command setup isolated while empty-UUID dispatch validation is tested.
ka_xdg_init() {
    return 0
}

# Role: Avoid touching a real session bus during CLI argument validation.
ka_dbus_prepare_session_address() {
    return 0
}

# Role: Avoid presentation terminal probes during CLI argument validation.
ka_cli_init_presentation() {
    return 0
}

# Role: Keep all empty-UUID probes inside the already-created test environment.
ka_ensure_runtime_dirs() {
    return 0
}

# Role: Avoid profile writes while CLI argument validation is tested.
ka_profile_init_defaults() {
    return 0
}

for cli_form in create configure delete pause resume send reset mode enter; do
    assert_eq $'2\t0' "$(empty_uuid_probe "$cli_form" '')" \
        "empty UUID for $cli_form returns 2 without reaching a request"
done

# Restore production CLI functions after the empty-UUID dispatch probes.
source "$TEST_ROOT/keepalive" --version >/dev/null

# Role: Keep CLI request setup isolated while the response sanitizer is exercised.
ka_cli_ensure_service() {
    return 0
}

# Role: Emit one daemon response containing terminal controls for CLI output tests.
ka_ipc_call() {
    printf 'ERROR\t%s\n' $'safe\033]52;c;INJECT\a'
}

response_output="$TEST_TMP/cli-response.out"
response_rc=0
ka_cli_request SEND_MAIN UUID >"$response_output" 2>/dev/null || response_rc=$?
assert_eq 1 "$response_rc" 'CLI propagates an ERROR daemon response'
assert_eq 'safe]52;c;INJECT' "$(<"$response_output")" \
    'CLI daemon response output strips ESC and BEL while retaining readable text'
assert_true 'CLI daemon response output contains no terminal controls' \
    no_terminal_controls "$(<"$response_output")"

# Role: Keep list refresh isolated while a plain-list type column is rendered.
ka_cli_refresh_for_list() {
    return 0
}

# Role: Avoid index I/O while a deterministic plain list row is rendered.
ka_tui_load_index() {
    return 0
}

declare -ga KA_R_UUID=('u') KA_R_BACKEND=('konsole') KA_R_TYPE=($'A\033]52;c;INJECT\a')
declare -ga KA_R_NAME=('name') KA_R_STATUS=('AVAILABLE') KA_R_MAIN_REMAIN=(0) KA_R_MAIN_INTERVAL=(1)
declare -ga KA_R_SEC_ENABLED=(0) KA_R_SEC_REMAIN=(0) KA_R_SEC_INTERVAL=(0)
declare -ga KA_R_NEXT_MAIN=() KA_R_NEXT_SECONDARY=() KA_R_LAST_DELIVERY_TIME=()
declare -ga KA_R_LAST_DELIVERY_EVENT=() KA_R_LAST_DELIVERY_RESULT=() KA_R_LAST_DELIVERY_DETAIL=()
list_output="$TEST_TMP/cli-list.out"
ka_cli_list >"$list_output"
assert_true 'plain list type column strips terminal controls' no_terminal_controls "$(<"$list_output")"
assert_contains "$list_output" 'A]52;c;INJECT' 'plain list retains readable type text after sanitization'

# Role: Emit a refresh response with controls so dispatch preserves its TSV boundary.
ka_ipc_call() {
    printf 'STATUS\t%s\n' $'refresh\033]52;c;INJECT\a'
}
refresh_output="$TEST_TMP/cli-refresh.out"
refresh_rc=0
ka_cli_main refresh >"$refresh_output" 2>/dev/null || refresh_rc=$?
assert_eq 0 "$refresh_rc" 'refresh accepts a daemon status response'
assert_eq $'STATUS\trefresh]52;c;INJECT' "$(<"$refresh_output")" \
    'refresh preserves STATUS<TAB>message shape while sanitizing the message'

ka_state_target_dir log-target
log_target_dir=$REPLY
mkdir -p "$log_target_dir" "$KA_LOGS_DIR"
printf 'victim\n' >"$TEST_TMP/log-victim"
ln -s "$TEST_TMP/log-victim" "$log_target_dir/state.tsv"
assert_eq 1 "$(logs_probe log-target)" 'logs refuses a symlinked target state.tsv'
assert_contains "$TEST_TMP/logs.err" 'no such keep-alive: log-target' \
    'symlinked state.tsv receives the unknown-target diagnostic'
rm -f -- "$log_target_dir/state.tsv"
mkdir "$log_target_dir/state.tsv"
assert_eq 1 "$(logs_probe log-target)" 'logs refuses a non-regular target state.tsv'

# --- Orca terminal show/list schema and display-name boundaries. ---
if command -v jq >/dev/null 2>&1; then
    orca_base="$TEST_TMP/orca-show-base.json"
    orca_show="$TEST_TMP/orca-show.json"
    orca_stub="$TEST_TMP/orca-show-stub"
    cat >"$orca_base" <<'JSON'
{"ok":true,"result":{"terminal":{"handle":"term-agent","ptyId":"pty-1","incarnationId":"inc-1","worktreeId":"wt-1","connected":true,"writable":true,"orphaned":false,"executionHostId":"host-1","tabId":"tab-1","leafId":"leaf-1","agentIdentity":"codex"}},"_meta":{"runtimeId":"runtime-1"}}
JSON
    cat >"$orca_stub" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
cat -- "$FAKE_ORCA_JSON_FILE"
SH
    chmod 700 "$orca_stub"
    export KEEPALIVE_ORCA_ENABLED=1 KEEPALIVE_ORCA_CLI="$orca_stub" KEEPALIVE_JQ
    KEEPALIVE_JQ=$(command -v jq)
    export KEEPALIVE_ORCA_TIMEOUT=5 FAKE_ORCA_JSON_FILE="$orca_show"
    KA_ORCA_CLI=''; KA_ORCA_JQ=''
    assert_true 'Orca show test resolves the isolated CLI and jq' ka_orca_find

    jq '.result.terminal.agentIdentity = ("x" * 129)' "$orca_base" >"$orca_show"
    assert_eq 22 "$(orca_show_probe)" 'Orca show rejects an overlong agentIdentity as transient schema 22'
    jq '.result.terminal.agentIdentity = "codex\u001b"' "$orca_base" >"$orca_show"
    assert_eq 22 "$(orca_show_probe)" 'Orca show rejects a control-bearing agentIdentity as transient schema 22'
    jq '.result.terminal.handle = ("x" * 513)' "$orca_base" >"$orca_show"
    assert_eq 22 "$(orca_show_probe)" 'Orca show rejects an overlong terminal handle as transient schema 22'
    assert_true 'Orca schema validation marks show-bound failures transient' ka_orca_validation_is_transient 22

    export KEEPALIVE_ORCA_CLI="$TEST_ROOT/tests/fixtures/orca-mock"
    KA_ORCA_CLI=''; KA_ORCA_JQ=''
    assert_true 'Orca list test resolves the fixture CLI and jq' ka_orca_find
    huge_title="$TEST_TMP/orca-title-huge"
    : >"$huge_title"
    for ((title_index = 0; title_index < 65537; title_index += 1)); do printf x >>"$huge_title"; done
    export FAKE_ORCA_TITLE_FILE="$huge_title"
    list_rows=$(ka_orca_discover)
    assert_eq $'#INCOMPLETE\tschema' "$list_rows" \
        'Orca list fails closed for a 65537-character title'

    medium_title="$TEST_TMP/orca-title-2000"
    : >"$medium_title"
    for ((title_index = 0; title_index < 2000; title_index += 1)); do printf x >>"$medium_title"; done
    export FAKE_ORCA_TITLE_FILE="$medium_title"
    list_rows=$(ka_orca_discover)
    list_row=${list_rows%%$'\n'*}
    list_marker=${list_rows##*$'\n'}
    IFS=$'\t' read -r list_id list_agent list_name list_directory _rest <<<"$list_row"
    assert_eq 256 "${#list_name}" 'Orca list truncates a normal 2000-character title to 256'
    assert_eq '' "${list_name//x/}" 'Orca list title truncation retains only title characters'
    assert_eq '#COMPLETE' "$list_marker" 'Orca list emits a complete marker for a bounded title'

    empty_title="$TEST_TMP/orca-title-empty"
    empty_path="$TEST_TMP/orca-worktree-path"
    : >"$empty_title"
    printf '/work/project/\n' >"$empty_path"
    export FAKE_ORCA_TITLE_FILE="$empty_title" FAKE_ORCA_PATH_FILE="$empty_path"
    list_rows=$(ka_orca_discover)
    list_row=${list_rows%%$'\n'*}
    IFS=$'\t' read -r list_id list_agent list_name list_directory _rest <<<"$list_row"
    assert_eq 'orca-runtime-1111-incarnation-2222' "$list_id" \
        'Orca empty-title fallback leaves the manager ID in its original column'
    assert_eq project "$list_name" 'Orca empty-title fallback uses the last non-empty worktree segment'
    assert_eq '/work/project/' "$list_directory" 'Orca empty-title fallback preserves the trailing-slash worktree path'
    unset FAKE_ORCA_TITLE_FILE FAKE_ORCA_PATH_FILE
    export KEEPALIVE_ORCA_ENABLED=0
else
    test_skip 'Orca show/list schema tests' 'jq is not installed'
fi

# --- Konsole discovery deadline must use the controllable monotonic source. ---
clock_file="$TEST_TMP/konsole-monotonic"
clock_counter="$TEST_TMP/konsole-clock-count"
clock_mock="$TEST_TMP/qdbus-clock-mock"
cat >"$clock_mock" <<'SH'
#!/usr/bin/env bash
set -Eeuo pipefail
count=0
if [[ -r ${FAKE_CLOCK_COUNTER:-} ]]; then IFS= read -r count <"$FAKE_CLOCK_COUNTER" || true; fi
[[ $count =~ ^[0-9]+$ ]] || count=0
count=$((count + 1))
printf '%s\n' "$count" >"$FAKE_CLOCK_COUNTER"
if [[ ${FAKE_CLOCK_OVERRUN:-0} == 1 && $count == 1 ]]; then
    printf '2001.000\n' >"$KEEPALIVE_MONOTONIC_FILE"
fi
exec "$FAKE_REAL_QDBUS" "$@"
SH
chmod 700 "$clock_mock"
export KEEPALIVE_QDBUS="$clock_mock" FAKE_REAL_QDBUS="$TEST_ROOT/tests/fixtures/qdbus-mock" \
    FAKE_PID=$$ FAKE_CLOCK_COUNTER="$clock_counter" KEEPALIVE_QDBUS_TIMEOUT=1 \
    KEEPALIVE_DISCOVERY_BUDGET_MS=100 KEEPALIVE_MONOTONIC_FILE="$clock_file"
KA_QDBUS=''
ka_qdbus_find
ka_classifier_init

# Role: Emit a deterministic recognized process classification for Konsole discovery tests.
ka_classifier_from_process_tree_set() {
    REPLY="Claude"$'\t'"$1"
}

# Role: Advance a synthetic wall clock so the fixed deadline test would fail on wall time.
ka_now_ms() {
    ((WALL_CLOCK_CALLS += 1))
    if ((WALL_CLOCK_CALLS == 1)); then REPLY=1000; else REPLY=1000000; fi
}
printf '1000.000\n' >"$clock_file"
: >"$clock_counter"
WALL_CLOCK_CALLS=0
unset FAKE_CLOCK_OVERRUN
wall_rows=$(ka_konsole_discover)
wall_marker=${wall_rows##*$'\n'}
assert_eq '#COMPLETE' "$wall_marker" \
    'Konsole discovery ignores a wall-clock jump when monotonic time stays within budget'
assert_eq 0 "$WALL_CLOCK_CALLS" 'Konsole discovery deadline does not call the wall clock when monotonic source is valid'

# Role: Keep a stable synthetic wall clock while monotonic time deliberately overruns.
ka_now_ms() {
    ((WALL_CLOCK_CALLS += 1))
    REPLY=2000
}
printf '2000.000\n' >"$clock_file"
: >"$clock_counter"
WALL_CLOCK_CALLS=0
export FAKE_CLOCK_OVERRUN=1
overrun_rows=$(ka_konsole_discover)
overrun_marker=${overrun_rows##*$'\n'}
assert_eq $'#INCOMPLETE\tbudget' "$overrun_marker" \
    'Konsole discovery marks a monotonic deadline overrun incomplete'
assert_eq 0 "$WALL_CLOCK_CALLS" 'Konsole overrun detection remains independent of wall-clock values'

# Keep the report count and all temporary state under the shared isolated test harness.
test_finish
