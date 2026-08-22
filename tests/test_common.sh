#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core

assert_eq '00:00' "$(ka_format_duration 0)" 'format zero duration'
assert_eq '25:00' "$(ka_format_duration 1500)" 'format minute duration'
assert_eq '01:01:01' "$(ka_format_duration 3661)" 'format hour duration'
assert_eq 'a_b-c.d' "$(ka_safe_id 'a b-c.d')" 'sanitize filename identifier'
assert_true 'positive integer accepted' ka_is_positive_int 42
assert_false 'zero is not positive' ka_is_positive_int 0

literal='$HOME `touch /tmp/NOPE` $(id); "quoted"'
ka_write_scalar "$TEST_TMP/literal" "$literal"
assert_eq "$literal" "$(ka_read_first_line "$TEST_TMP/literal")" 'literal shell metacharacters remain data'

printf '%s' 'no-newline-value' >"$TEST_TMP/no-newline"
assert_eq 'no-newline-value' "$(ka_read_first_line "$TEST_TMP/no-newline")" 'scalar reader preserves final line without newline'
[[ ! -e /tmp/NOPE ]] || rm -f /tmp/NOPE

clock_file="$TEST_TMP/monotonic.clock"
ka_write_scalar "$clock_file" '123.75 999.00'
export KEEPALIVE_MONOTONIC_FILE=$clock_file
ka_now_monotonic
assert_eq 123 "$REPLY" 'injectable monotonic clock returns integer seconds in REPLY'
ka_write_scalar "$clock_file" 'not-a-clock'
assert_false 'invalid injected monotonic clock is rejected' ka_now_monotonic
unset KEEPALIVE_MONOTONIC_FILE

test_finish
