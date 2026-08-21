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

test_finish
