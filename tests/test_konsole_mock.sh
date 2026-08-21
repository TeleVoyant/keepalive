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
ka_classifier_from_process_tree() { printf 'Claude\t%s\n' "$1"; }

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

test_finish
