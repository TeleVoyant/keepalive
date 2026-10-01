#!/usr/bin/env bash
# Atomic file publication, startup hygiene, deletion failure, and sleep resource tests.
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
ka_state_init_arrays

# Role: Return a test-owned file's numeric permission mode.
mode_of() {
    stat -Lc '%a' -- "$1"
}

# Role: Exercise one atomic writer under both umask paths and both caller noclobber states.
atomic_writer_case() {
    local writer=$1
    local umask_mode=$2
    local noclobber_mode=$3
    local destination content expected_file rc after_state
    local -a leftovers=()
    destination="$TEST_TMP/atomic-${writer}-${umask_mode}-${noclobber_mode}"
    content="exact ${writer} payload with spaces\nsecond line"
    expected_file="$destination.expected"
    printf '%s' "$content" >"$expected_file"

    if [[ $umask_mode == private ]]; then
        export KA_PRIVATE_UMASK=1
        umask 077
    else
        unset KA_PRIVATE_UMASK
        umask 000
    fi
    if [[ $noclobber_mode == on ]]; then
        set -o noclobber
    else
        set +o noclobber
    fi

    if (
        if [[ $writer == value ]]; then
            ka_atomic_write_value "$destination" "$content"
        else
            printf '%s' "$content" | ka_atomic_write "$destination"
        fi
    ); then
        rc=0
    else
        rc=$?
    fi
    assert_eq 0 "$rc" "$writer writer succeeds in a subshell ($umask_mode umask, noclobber $noclobber_mode)"
    assert_true "$writer writer preserves exact bytes ($umask_mode umask, noclobber $noclobber_mode)" \
        cmp -s "$expected_file" "$destination"
    assert_eq 600 "$(mode_of "$destination")" \
        "$writer writer uses mode 0600 ($umask_mode umask, noclobber $noclobber_mode)"

    shopt -s nullglob
    for path in "$TEST_TMP"/.atomic-${writer}-${umask_mode}-${noclobber_mode}.tmp.*; do
        [[ -f $path ]] && leftovers+=("$path")
    done
    shopt -u nullglob
    assert_eq 0 "${#leftovers[@]}" \
        "$writer writer leaves no temporary regular files ($umask_mode umask, noclobber $noclobber_mode)"
    if [[ $- == *C* ]]; then
        after_state=on
    else
        after_state=off
    fi
    assert_eq "$noclobber_mode" "$after_state" \
        "$writer writer preserves the caller's noclobber state ($umask_mode umask)"
}

for writer_kind in value stream; do
    for umask_kind in private permissive; do
        for noclobber_kind in off on; do
            atomic_writer_case "$writer_kind" "$umask_kind" "$noclobber_kind"
        done
    done
done
umask 077
export KA_PRIVATE_UMASK=1
set +o noclobber

# Role: Prove an existing FIFO candidate is skipped without allowing a blocking open.
atomic_fifo_case() {
    local directory="$TEST_TMP/atomic-fifo-probe"
    local destination="$directory/result"
    local seed=4242 candidate watchdog_fifo writer_pid watchdog_pid watchdog_signal_fd
    local writer_rc=0 watchdog_rc=0
    local -a leftovers=()
    mkdir -p "$directory"
    unset SRANDOM
    RANDOM=$seed
    candidate="$directory/.result.tmp.$$.$(printf '%s%s' "${SRANDOM:-$RANDOM}" "${SRANDOM:-$RANDOM}")"
    mkfifo -- "$candidate"
    RANDOM=$seed
    watchdog_fifo="$directory/watchdog.fifo"
    mkfifo -- "$watchdog_fifo"

    (
        ka_atomic_write_value "$destination" 'fifo candidate is skipped'
    ) &
    writer_pid=$!
    (
        local fd
        exec {fd}<>"$watchdog_fifo"
        read -r -t 1 -u "$fd" _watchdog_message || true
        kill "$writer_pid" 2>/dev/null || true
        exec {fd}>&- 2>/dev/null || true
    ) &
    watchdog_pid=$!

    if wait "$writer_pid"; then
        writer_rc=0
    else
        writer_rc=$?
    fi
    if exec {watchdog_signal_fd}<>"$watchdog_fifo"; then
        printf 'done\n' >&"$watchdog_signal_fd"
        exec {watchdog_signal_fd}>&- 2>/dev/null || true
    fi
    if wait "$watchdog_pid"; then
        watchdog_rc=0
    else
        watchdog_rc=$?
    fi
    assert_eq 0 "$writer_rc" 'a pre-existing FIFO temp candidate is skipped without blocking'
    assert_true 'the FIFO deadline watchdog is reaped' test "$watchdog_rc" -eq 0
    assert_true 'the pre-existing FIFO remains untouched' test -p "$candidate"
    assert_eq 'fifo candidate is skipped' "$(cat -- "$destination")" \
        'the atomic writer commits after skipping the FIFO candidate'
    shopt -s nullglob
    for path in "$directory"/.result.tmp.*; do
        [[ -f $path ]] && leftovers+=("$path")
    done
    shopt -u nullglob
    assert_eq 0 "${#leftovers[@]}" 'skipping a FIFO leaves no regular temporary files'
    rm -f -- "$candidate" "$watchdog_fifo" "$destination"
}

atomic_fifo_case

# Preserve the product close implementation so this wrapper can inject the pathname swap
# after the writer has written bytes and then exercise the real inode/path verification.
atomic_close_definition=$(declare -f ka_atomic_close)
atomic_close_original_definition=${atomic_close_definition/ka_atomic_close /ka_atomic_close_original }
eval "$atomic_close_original_definition"

# Role: Replace the staged pathname with a symlink immediately before the real close check.
ka_atomic_close() {
    local temporary=$KA_ATOMIC_TMP
    rm -f -- "$temporary"
    ln -s -- "$ATOMIC_SWAP_TARGET" "$temporary"
    ka_atomic_close_original
}

# Role: Exercise close-time path swapping for one atomic writer.
atomic_swap_case() {
    local writer=$1
    local destination="$TEST_TMP/swap-${writer}-destination"
    local external="$TEST_TMP/swap-${writer}-external"
    local content='swap probe payload'
    local rc
    local -a leftovers=()
    printf 'external remains unchanged' >"$external"
    printf 'old destination remains' >"$destination"
    ATOMIC_SWAP_TARGET=$external

    if (
        if [[ $writer == value ]]; then
            ka_atomic_write_value "$destination" "$content"
        else
            printf '%s' "$content" | ka_atomic_write "$destination"
        fi
    ); then
        rc=0
    else
        rc=$?
    fi
    assert_true "$writer fails when its temp pathname is swapped for a symlink" test "$rc" -ne 0
    assert_eq 'external remains unchanged' "$(cat -- "$external")" \
        "$writer close-time swap never writes the symlink target"
    assert_eq 'old destination remains' "$(cat -- "$destination")" \
        "$writer close-time swap never commits the destination"
    shopt -s nullglob
    for path in "$TEST_TMP"/.swap-${writer}-destination.tmp.*; do
        [[ -f $path ]] && leftovers+=("$path")
    done
    shopt -u nullglob
    assert_eq 0 "${#leftovers[@]}" "$writer close-time swap cleans its staged file"
}

for writer_kind in value stream; do
    atomic_swap_case "$writer_kind"
done
unset -f ka_atomic_close
# Restore the original function after the close-time race probes.
eval "$atomic_close_definition"

# Role: Seed one available discovery row for index publication probes.
seed_index_probe() {
    local uuid=$1
    KA_T_UUIDS=()
    KA_D_UUIDS=("$uuid")
    KA_D_BACKEND[$uuid]=konsole
    KA_D_TYPE[$uuid]=Claude
    KA_D_NAME[$uuid]='Index probe'
    KA_D_DIR[$uuid]='/work/index-probe'
}

index_uuid='index-probe-uuid'
KA_INDEX_FILE="$TEST_TMP/index.tsv"
seed_index_probe "$index_uuid"
assert_true 'initial index publication succeeds' ka_state_publish_index
index_inode=$(stat -Lc '%i' -- "$KA_INDEX_FILE")
cp -- "$KA_INDEX_FILE" "$TEST_TMP/index.expected"
assert_true 'identical index publication succeeds' ka_state_publish_index
assert_eq "$index_inode" "$(stat -Lc '%i' -- "$KA_INDEX_FILE")" \
    'identical index payload keeps the existing inode'

KA_D_NAME[$index_uuid]='Changed index probe'
assert_true 'changed index publication succeeds' ka_state_publish_index
changed_inode=$(stat -Lc '%i' -- "$KA_INDEX_FILE")
assert_true 'changed index payload replaces the inode' test "$changed_inode" -ne "$index_inode"
assert_contains "$KA_INDEX_FILE" 'Changed index probe' 'changed index payload is committed'
cp -- "$KA_INDEX_FILE" "$TEST_TMP/index.expected.changed"

printf 'tampered bytes\n' >"$KA_INDEX_FILE"
tampered_inode=$(stat -Lc '%i' -- "$KA_INDEX_FILE")
assert_true 'wrong same-owner index bytes are repaired' ka_state_publish_index
assert_true 'repairing wrong index bytes replaces the inode' \
    test "$(stat -Lc '%i' -- "$KA_INDEX_FILE")" -ne "$tampered_inode"
assert_true 'repaired index bytes match the current payload' \
    cmp -s "$TEST_TMP/index.expected.changed" "$KA_INDEX_FILE"

chmod 000 -- "$KA_INDEX_FILE"
assert_true 'an unreadable same-owner index is repaired' ka_state_publish_index
assert_eq 600 "$(mode_of "$KA_INDEX_FILE")" 'index repair restores private mode after chmod 000'
assert_true 'unreadable-index repair restores the payload' \
    cmp -s "$TEST_TMP/index.expected.changed" "$KA_INDEX_FILE"

index_external="$TEST_TMP/index-external"
printf 'external index target remains unchanged' >"$index_external"
rm -f -- "$KA_INDEX_FILE"
ln -s -- "$index_external" "$KA_INDEX_FILE"
assert_true 'a symlinked index destination is repaired' ka_state_publish_index
assert_false 'index publication replaces the symlink itself' test -L "$KA_INDEX_FILE"
assert_eq 'external index target remains unchanged' "$(cat -- "$index_external")" \
    'index publication never follows a destination symlink'
assert_true 'repaired symlink index has the current payload' \
    cmp -s "$TEST_TMP/index.expected.changed" "$KA_INDEX_FILE"

rm -f -- "$KA_INDEX_FILE"
mkdir -- "$KA_INDEX_FILE"
printf 'directory sentinel' >"$KA_INDEX_FILE/sentinel"
index_rc=0
ka_state_publish_index || index_rc=$?
assert_true 'a directory index destination is rejected' test "$index_rc" -ne 0
assert_true 'rejected directory index remains a directory' test -d "$KA_INDEX_FILE"
assert_eq 'directory sentinel' "$(cat -- "$KA_INDEX_FILE/sentinel")" \
    'rejected directory index remains untouched'
shopt -s nullglob
index_leftovers=()
for path in "$TEST_TMP"/.index.tsv.tmp.*; do
    [[ -f $path ]] && index_leftovers+=("$path")
done
shopt -u nullglob
assert_eq 0 "${#index_leftovers[@]}" 'rejected directory index leaves no staged sibling'

# Versioned companion pruning is constrained to a real target directory and its reference.
prune_dir="$KA_TARGETS_DIR/prune-target"
mkdir -p "$prune_dir"
chmod 700 "$prune_dir"
ka_write_scalar "$prune_dir/state.tsv" $'secondary_message_file\tsecondary_message.111.222'
ka_write_scalar "$prune_dir/secondary_message.111.222" referenced
ka_write_scalar "$prune_dir/secondary_message.333.444" unreferenced
ka_write_scalar "$prune_dir/secondary_message.legacy" legacy
prune_external="$TEST_TMP/prune-external"
mkdir -p "$prune_external"
ka_write_scalar "$prune_external/outside" 'outside stays'
ln -s -- "$prune_external/outside" "$prune_dir/secondary_message.555.666"
assert_true 'secondary companion pruning completes for a real target' \
    ka_state_prune_secondary_companions "$prune_dir"
assert_true 'the referenced secondary companion is kept' test -f "$prune_dir/secondary_message.111.222"
assert_false 'an unreferenced versioned companion is removed' \
    test -e "$prune_dir/secondary_message.333.444"
assert_true 'a non-versioned companion is not removed' test -f "$prune_dir/secondary_message.legacy"
assert_true 'a symlinked companion is not followed or removed' \
    test -L "$prune_dir/secondary_message.555.666"
assert_eq 'outside stays' "$(cat -- "$prune_external/outside")" \
    'a symlinked companion target remains unchanged'

prune_link_external="$TEST_TMP/prune-link-external"
mkdir -p "$prune_link_external"
ka_write_scalar "$prune_link_external/secondary_message.777.888" 'outside target dir'
ln -s -- "$prune_link_external" "$KA_TARGETS_DIR/prune-link"
assert_true 'pruning a symlinked target directory fails closed' \
    ka_state_prune_secondary_companions "$KA_TARGETS_DIR/prune-link"
assert_true 'a symlinked target directory is not traversed' \
    test -f "$prune_link_external/secondary_message.777.888"

root_companion="$KA_TARGETS_DIR/secondary_message.999.000"
ka_write_scalar "$root_companion" 'root must not be pruned'
assert_true 'root-level companion pruning returns safely' \
    ka_state_prune_secondary_companions "$KA_TARGETS_DIR"
assert_true 'pruning is never allowed to target the targets root' test -f "$root_companion"

sweep_target="$KA_TARGETS_DIR/sweep-target"
mkdir -p "$sweep_target"
chmod 700 "$sweep_target"
runtime_stale="$KA_RUNTIME_DIR/.runtime.tmp.1"
target_stale="$sweep_target/.target.tmp.2"
log_stale="$KA_LOGS_DIR/session.log.trim.3"
ka_write_scalar "$runtime_stale" stale
ka_write_scalar "$target_stale" stale
ka_write_scalar "$log_stale" stale
runtime_keep="$KA_RUNTIME_DIR/not-a-temp-file"
target_keep="$sweep_target/.keep.tmp"
log_keep="$KA_LOGS_DIR/session.log.trim"
ka_write_scalar "$runtime_keep" keep
ka_write_scalar "$target_keep" keep
ka_write_scalar "$log_keep" keep
sweep_external="$TEST_TMP/sweep-external"
mkdir -p "$sweep_external"
ka_write_scalar "$sweep_external/.foreign.tmp.4" 'outside stays'
ln -s -- "$sweep_external" "$KA_TARGETS_DIR/sweep-link"
assert_true 'startup temp-file sweep completes' ka_state_sweep_temp_files
assert_false 'runtime stale atomic temp is swept' test -e "$runtime_stale"
assert_false 'target stale atomic temp is swept' test -e "$target_stale"
assert_false 'stale trimmed log temp is swept' test -e "$log_stale"
assert_true 'non-matching runtime temp is kept' test -f "$runtime_keep"
assert_true 'non-matching target temp is kept' test -f "$target_keep"
assert_true 'non-matching trimmed-log name is kept' test -f "$log_keep"
assert_true 'sweep never follows a symlinked target directory' \
    test -f "$sweep_external/.foreign.tmp.4"

runtime_real="$TEST_TMP/runtime-real"
runtime_link_external="$TEST_TMP/runtime-link-external"
mv -- "$KA_RUNTIME_DIR" "$runtime_real"
mkdir -p "$runtime_link_external"
ka_write_scalar "$runtime_link_external/.foreign-root.tmp.5" 'outside runtime root'
ln -s -- "$runtime_link_external" "$KA_RUNTIME_DIR"
assert_true 'sweep returns safely for a symlinked runtime root' ka_state_sweep_temp_files
assert_true 'a symlinked runtime root is never traversed' \
    test -f "$runtime_link_external/.foreign-root.tmp.5"
rm -f -- "$KA_RUNTIME_DIR"
mv -- "$runtime_real" "$KA_RUNTIME_DIR"

targets_real="$TEST_TMP/targets-real"
targets_link_external="$TEST_TMP/targets-link-external"
mv -- "$KA_TARGETS_DIR" "$targets_real"
mkdir -p "$targets_link_external/child"
ka_write_scalar "$targets_link_external/child/.foreign-target-root.tmp.6" 'outside targets root'
ln -s -- "$targets_link_external" "$KA_TARGETS_DIR"
assert_true 'sweep returns safely for a symlinked targets root' ka_state_sweep_temp_files
assert_true 'a symlinked targets root is never traversed' \
    test -f "$targets_link_external/child/.foreign-target-root.tmp.6"
rm -f -- "$KA_TARGETS_DIR"
mv -- "$targets_real" "$KA_TARGETS_DIR"

# Role: Make rm fail only for the target directory under the delete-failure probe.
rm() {
    local arg
    if [[ -n ${FAIL_RM_DIR:-} ]]; then
        for arg in "$@"; do
            [[ $arg == "$FAIL_RM_DIR" ]] && return 73
        done
    fi
    command rm "$@"
}

delete_uuid='delete-rm-failure-uuid'
ka_state_register_uuid "$delete_uuid"
KA_T_STATUS[$delete_uuid]=ACTIVE
KA_T_TYPE[$delete_uuid]=Claude
KA_T_NAME[$delete_uuid]='Delete failure probe'
ka_state_target_dir "$delete_uuid"
delete_dir=$REPLY
mkdir -p "$delete_dir"
chmod 700 "$delete_dir"
ka_write_scalar "$delete_dir/state.tsv" 'kept checkpoint'
FAIL_RM_DIR=$delete_dir
delete_rc=0
ka_state_delete_target "$delete_uuid" || delete_rc=$?
assert_true 'target deletion reports an rm failure' test "$delete_rc" -ne 0
assert_true 'target deletion keeps the in-memory target after rm failure' ka_state_has_target "$delete_uuid"
assert_eq ACTIVE "${KA_T_STATUS[$delete_uuid]}" \
    'target deletion keeps the target status after rm failure'
assert_true 'target deletion keeps the runtime directory after rm failure' test -d "$delete_dir"
unset FAIL_RM_DIR
unset -f rm

# Role: Read this Bash process CPU tick count for a no-busy-loop sleep assertion.
process_cpu_ticks() {
    local pid comm state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime _rest
    read -r pid comm state ppid pgrp session tty_nr tpgid flags minflt cminflt majflt cmajflt utime stime _rest <"/proc/$$/stat"
    REPLY=$((utime + stime))
}

unset KA_SLEEP_FD
process_cpu_ticks
sleep_cpu_before=$REPLY
sleep_start_us=${EPOCHREALTIME/./}
if ka_sleep 0.12; then
    sleep_rc=0
else
    sleep_rc=$?
fi
sleep_end_us=${EPOCHREALTIME/./}
process_cpu_ticks
sleep_cpu_after=$REPLY
sleep_elapsed_ms=$(( (sleep_end_us - sleep_start_us) / 1000 ))
sleep_cpu_ticks_used=$((sleep_cpu_after - sleep_cpu_before))
assert_eq 0 "$sleep_rc" 'ka_sleep completes its requested delay'
assert_true 'ka_sleep lasts approximately the requested time' test "$sleep_elapsed_ms" -ge 80
assert_true 'ka_sleep remains within a bounded delay' test "$sleep_elapsed_ms" -le 1000
assert_true 'ka_sleep does not busy-loop the shell' test "$sleep_cpu_ticks_used" -lt 10
if [[ -n ${KA_SLEEP_FD:-} && $KA_SLEEP_FD != -1 ]]; then
    sleep_fd=$KA_SLEEP_FD
    { exec {sleep_fd}<&-; } 2>/dev/null || true
fi
unset KA_SLEEP_FD

# Role: Observe the external sleep fallback without adding another real delay.
sleep() {
    FALLBACK_SLEEP_CALLED=1
    FALLBACK_SLEEP_ARGUMENT=${1-}
    return 0
}

fallback_fifo="$TEST_TMP/fallback.fifo"
mkfifo -- "$fallback_fifo"
exec {fallback_fd}<>"$fallback_fifo"
printf 'wake immediately\n' >&"$fallback_fd"
KA_SLEEP_FD=$fallback_fd
FALLBACK_SLEEP_CALLED=0
FALLBACK_SLEEP_ARGUMENT=''
if ka_sleep 0.17; then
    fallback_rc=0
else
    fallback_rc=$?
fi
assert_eq 0 "$fallback_rc" 'immediate ka_sleep fallback returns successfully'
assert_eq 1 "$FALLBACK_SLEEP_CALLED" 'immediate ka_sleep fallback calls sleep'
assert_eq 0.17 "$FALLBACK_SLEEP_ARGUMENT" 'fallback sleep receives the requested duration'
assert_eq -1 "$KA_SLEEP_FD" 'immediate ka_sleep fallback marks its fd unusable'
assert_false 'immediate ka_sleep fallback closes the old fd' test -e "/proc/$$/fd/$fallback_fd"
unset -f sleep
rm -f -- "$fallback_fifo"

# All probes use only the isolated test environment and have no daemon/client processes.
test_finish
