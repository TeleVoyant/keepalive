#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
export KEEPALIVE_QDBUS="$TEST_ROOT/tests/fixtures/qdbus-mock"
export FAKE_PID=$$
KA_QDBUS=''
ka_qdbus_find
ka_classifier_init

# Role: Deterministically make the current test process appear as Claude for discovery.
ka_classifier_from_process_tree_set() { REPLY="Claude"$'\t'"$1"; }

row=$(ka_konsole_discover)
IFS=$'\t' read -r uuid type name directory service path term_pid fgpid ai_pid ai_start cmd <<<"$row"
assert_eq '12345678-1234-4123-8123-123456789abc' "$uuid" 'discover Konsole shellSessionId UUID'
assert_eq Claude "$type" 'discovery classifies recognized AI process'
assert_eq 'org.kde.konsole-100' "$service" 'discovery retains D-Bus service address'
assert_eq '/Sessions/1' "$path" 'discovery retains D-Bus session path'
assert_eq "$$" "$term_pid" 'discovery records terminal PID'

assert_true 'strict target validator accepts exact mocked identity' ka_konsole_validate_target "$service" "$path" "$uuid" "$term_pid" "$ai_pid" "$ai_start"
assert_false 'strict target validator rejects replacement UUID' ka_konsole_validate_target "$service" "$path" 'different-uuid' "$term_pid" "$ai_pid" "$ai_start"

hang_file="$TEST_TMP/qdbus.hang"
touch "$hang_file"
export FAKE_QDBUS_HANG_FILE=$hang_file
export KEEPALIVE_QDBUS_TIMEOUT=1
if ka_konsole_validate_target "$service" "$path" "$uuid" "$term_pid" "$ai_pid" "$ai_start"; then timeout_rc=0; else timeout_rc=$?; fi
assert_eq 20 "$timeout_rc" 'bounded qdbus validation reports a transient timeout'

export KEEPALIVE_NOTIFY_SEND=$KEEPALIVE_QDBUS
export KEEPALIVE_NOTIFY_TIMEOUT=1
if ka_notify_call 'title' 'body'; then notify_rc=0; else notify_rc=$?; fi
assert_eq 124 "$notify_rc" 'desktop notification subprocess is terminated at its deadline'
rm -f -- "$hang_file"
unset FAKE_QDBUS_HANG_FILE KEEPALIVE_QDBUS_TIMEOUT KEEPALIVE_NOTIFY_SEND KEEPALIVE_NOTIFY_TIMEOUT

list_fail_file="$TEST_TMP/qdbus-list-fail"
touch "$list_fail_file"
export FAKE_QDBUS_LIST_FAIL_FILE=$list_fail_file
list_fail_output=$(ka_konsole_discover)
assert_eq $'#INCOMPLETE\tcommand-1' "$list_fail_output" \
    'a failed Konsole service enumeration marks the pass incomplete'
rm -f -- "$list_fail_file"
unset FAKE_QDBUS_LIST_FAIL_FILE

path_fail_file="$TEST_TMP/qdbus-path-fail"
touch "$path_fail_file"
export FAKE_QDBUS_PATH_FAIL_FILE=$path_fail_file
# A service whose session list errors (a window closing mid-pass) is skipped; only a
# timeout leaves the pass unknowable, so only a timeout marks it incomplete.
path_fail_output=$(ka_konsole_discover)
assert_eq '#COMPLETE' "$path_fail_output" \
    'a Konsole service whose session list errors is skipped without failing the pass'
export FAKE_QDBUS_PATH_FAIL_RC=124
path_fail_output=$(ka_konsole_discover)
assert_eq $'#INCOMPLETE\tcommand-124' "$path_fail_output" \
    'a timed-out Konsole session-path enumeration marks the pass incomplete'
rm -f -- "$path_fail_file"
unset FAKE_QDBUS_PATH_FAIL_FILE FAKE_QDBUS_PATH_FAIL_RC

empty_bus_file="$TEST_TMP/qdbus-empty"
touch "$empty_bus_file"
export FAKE_QDBUS_EMPTY_FILE=$empty_bus_file
empty_bus_output=$(ka_konsole_discover)
assert_eq '#COMPLETE' "$empty_bus_output" \
    'a genuinely empty Konsole bus result remains complete'
rm -f -- "$empty_bus_file"
unset FAKE_QDBUS_EMPTY_FILE

# A discovery pass that runs out of budget must keep the previous snapshot rather than
# publishing a truncated one, which would look like sessions disappearing.
source "$TEST_ROOT/lib/logging.sh"; source "$TEST_ROOT/lib/notifications.sh"
source "$TEST_ROOT/lib/profile.sh"; source "$TEST_ROOT/lib/state.sh"
ka_state_init_arrays

# Role: Emit one complete discovery pass for snapshot-commit tests.
ka_konsole_discover_rows() { KA_DISCOVERY_ROWS=($'u1\tClaude\tProj\t/w\torg.kde.konsole-1\t/Sessions/1\t10\t11\t11\t99\tclaude' '#COMPLETE'); }
assert_true 'a complete pass is committed' ka_state_refresh_discovery
assert_eq 1 "${#KA_D_UUIDS[@]}" 'the complete pass published one session'

# Role: Emit a pass that hit its budget partway through.
ka_konsole_discover_rows() { KA_DISCOVERY_ROWS=('#INCOMPLETE'); }
assert_false 'a truncated pass reports failure' ka_state_refresh_discovery
assert_eq 1 "${#KA_D_UUIDS[@]}" 'the previous snapshot survives a truncated pass'
assert_eq 1 "$KA_DISCOVERY_STALE" 'the truncated pass is flagged stale for the caller'

# Role: Emit a complete pass with no sessions at all.
ka_konsole_discover_rows() { KA_DISCOVERY_ROWS=('#COMPLETE'); }
assert_true 'an empty complete pass is committed' ka_state_refresh_discovery
assert_eq 0 "${#KA_D_UUIDS[@]}" 'a genuinely empty session list replaces the snapshot'

test_finish
