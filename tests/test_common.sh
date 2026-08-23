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

# ka_strip_controls previously removed only a named handful of control characters.
assert_eq 'abc' "$(ka_strip_controls $'a\x01b\x7fc')" 'all C0 controls and DEL are stripped'
assert_eq 'a b' "$(ka_strip_controls $'a\tb')" 'tabs become spaces'

ka_now_ms
assert_true 'millisecond clock returns a plausible epoch value' [ "$REPLY" -gt 1000000000000 ]

# A staged directory swap must roll back rather than destroy the live copy.
staging_root="$TEST_TMP/stage"; mkdir -p "$staging_root/live" "$staging_root/new"
printf 'old\n' >"$staging_root/live/001"
printf 'new\n' >"$staging_root/new/001"
assert_true 'staged commit replaces the destination' ka_commit_staged_dir "$staging_root/new" "$staging_root/live"
assert_eq 'new' "$(cat "$staging_root/live/001")" 'committed content replaces the original'
assert_false 'a missing staging directory fails' ka_commit_staged_dir "$staging_root/absent" "$staging_root/live"
assert_eq 'new' "$(cat "$staging_root/live/001")" 'a failed commit leaves the destination intact'

mkdir -p "$staging_root/orphan.staged.1" "$staging_root/orphan.trash.2"
ka_cleanup_staged_dirs "$staging_root"
assert_false 'abandoned staging directories are swept' test -d "$staging_root/orphan.staged.1"
assert_false 'abandoned rollback directories are swept' test -d "$staging_root/orphan.trash.2"

# Runtime base precedence. A client whose environment lacks XDG_RUNTIME_DIR - su, sudo,
# cron, non-interactive remote exec - must still find the directory the daemon uses,
# instead of silently addressing /tmp and reporting the service as unavailable.
saved_runtime=${XDG_RUNTIME_DIR:-}
per_user_stub="$TEST_TMP/peruser"
mkdir -p "$per_user_stub"
export KEEPALIVE_PER_USER_RUNTIME="$per_user_stub"

export XDG_RUNTIME_DIR="$TEST_TMP/session"
mkdir -p "$XDG_RUNTIME_DIR"
ka_xdg_resolve_runtime_base
assert_eq "$TEST_TMP/session" "$KA_RUNTIME_BASE" 'an available XDG_RUNTIME_DIR wins'
assert_eq xdg "$KA_RUNTIME_SOURCE" 'the XDG source is recorded'

unset XDG_RUNTIME_DIR
ka_xdg_resolve_runtime_base
assert_eq "$per_user_stub" "$KA_RUNTIME_BASE" 'without XDG_RUNTIME_DIR the per-user runtime directory is used'
assert_eq per-user "$KA_RUNTIME_SOURCE" 'the per-user source is recorded'

export KEEPALIVE_PER_USER_RUNTIME="$TEST_TMP/absent"
ka_xdg_resolve_runtime_base
assert_eq "/tmp/keepalive-$UID" "$KA_RUNTIME_BASE" 'with neither available the /tmp fallback is used'
assert_eq fallback "$KA_RUNTIME_SOURCE" 'the fallback source is recorded'

# Only the guessable /tmp fallback needs ownership and symlink checks.
KA_RUNTIME_SOURCE=fallback
KA_RUNTIME_BASE="$TEST_TMP/evil"
ln -s /tmp "$KA_RUNTIME_BASE"
assert_false 'a symlinked fallback base is refused' ka_runtime_secure
rm -f "$KA_RUNTIME_BASE"
KA_RUNTIME_BASE="$TEST_TMP/fallback"
assert_true 'an owned fallback base is accepted' ka_runtime_secure
KA_RUNTIME_SOURCE=xdg
KA_RUNTIME_BASE="$TEST_TMP/evil2"
ln -s /tmp "$KA_RUNTIME_BASE"
assert_true 'a session-managed base is not second-guessed' ka_runtime_secure
rm -f "$KA_RUNTIME_BASE"

unset KEEPALIVE_PER_USER_RUNTIME
[[ -n $saved_runtime ]] && export XDG_RUNTIME_DIR=$saved_runtime

test_finish
