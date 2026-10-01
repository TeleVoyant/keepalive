#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source "$TEST_ROOT/lib/common.sh"
source "$TEST_ROOT/lib/xdg.sh"

runtime_children=(targets quarantine requests responses logs)

# Role: Return a test-owned directory's numeric mode.
mode_of() {
    stat -Lc '%a' -- "$1"
}

# Role: List direct entries so a rejected destination can prove it was not traversed.
directory_entries() {
    find "$1" -mindepth 1 -maxdepth 1 -print | LC_ALL=C sort
}

# Role: Replace chmod temporarily so permission-hardening failures are observable.
chmod() {
    local path
    for path in "$@"; do
        if [[ -n ${chmod_fail_path:-} && $path == "$chmod_fail_path" ]]; then
            return 73
        fi
    done
    command chmod "$@"
}

# Role: Select fresh test-owned XDG roots and resolve all Keep Alive paths.
prepare_case() {
    local name=$1 root="$TEST_TMP/$1"
    export HOME="$root/home"
    export XDG_CONFIG_HOME="$root/config"
    export XDG_RUNTIME_DIR="$root/runtime"
    export XDG_STATE_HOME="$root/state"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME"
    command chmod 700 "$XDG_RUNTIME_DIR"
    ka_xdg_init
}

# A symlink anywhere in the runtime tree must be rejected before chmod or mkdir can
# follow it.  The target is deliberately outside the managed tree and starts permissive;
# preserving both its mode and its contents catches accidental traversal.
prepare_case symlink-root
external="$TEST_TMP/symlink-root/external"
mkdir -p "$external"
command chmod 755 "$external"
printf 'untouched\n' >"$external/sentinel"
ln -s "$external" "$KA_RUNTIME_DIR"
rc=0
ka_ensure_runtime_dirs >"$TEST_TMP/symlink-root.out" 2>&1 || rc=$?
assert_true 'a symlinked runtime directory is rejected' test "$rc" -ne 0
assert_eq 755 "$(mode_of "$external")" 'rejecting the runtime symlink leaves its target mode unchanged'
assert_eq untouched "$(<"$external/sentinel")" 'rejecting the runtime symlink leaves its target contents unchanged'
assert_eq "$external/sentinel" "$(directory_entries "$external")" \
    'rejecting the runtime symlink does not create children in its target'

for child in "${runtime_children[@]}"; do
    prepare_case "symlink-child-$child"
    mkdir -p "$KA_RUNTIME_DIR"
    external="$TEST_TMP/symlink-child-$child/external"
    mkdir -p "$external"
    command chmod 755 "$external"
    printf 'untouched\n' >"$external/sentinel"
    ln -s "$external" "$KA_RUNTIME_DIR/$child"
    rc=0
    ka_ensure_runtime_dirs >"$TEST_TMP/symlink-child-$child.out" 2>&1 || rc=$?
    assert_true "a symlinked runtime child is rejected: $child" test "$rc" -ne 0
    assert_eq 755 "$(mode_of "$external")" \
        "rejecting runtime child $child leaves its target mode unchanged"
    assert_eq untouched "$(<"$external/sentinel")" \
        "rejecting runtime child $child leaves its target contents unchanged"
    assert_eq "$external/sentinel" "$(directory_entries "$external")" \
        "rejecting runtime child $child does not create children in its target"
done

# New runtime/config components are private, and a later preparation pass repairs
# permissive modes left by an older installation or manual intervention.
prepare_case permissions
ka_ensure_runtime_dirs
ka_ensure_config_dirs
runtime_paths=(
    "$KA_RUNTIME_DIR" "$KA_TARGETS_DIR" "$KA_QUARANTINE_DIR" "$KA_REQUESTS_DIR"
    "$KA_RESPONSES_DIR" "$KA_LOGS_DIR"
)
config_paths=("$KA_CONFIG_DIR" "$KA_PROFILE_DIR" "$KA_PROFILE_DIR/messages")
for path in "${runtime_paths[@]}"; do
    assert_true "new runtime component is a directory: $path" test -d "$path"
    assert_eq 700 "$(mode_of "$path")" "new runtime component is mode 700: $path"
done
for path in "${config_paths[@]}"; do
    assert_true "new config component is a directory: $path" test -d "$path"
    assert_eq 700 "$(mode_of "$path")" "new config component is mode 700: $path"
done
for path in "${runtime_paths[@]}" "${config_paths[@]}"; do
    command chmod 755 "$path"
done
ka_ensure_runtime_dirs
ka_ensure_config_dirs
for path in "${runtime_paths[@]}" "${config_paths[@]}"; do
    assert_eq 700 "$(mode_of "$path")" "permissive component is corrected to mode 700: $path"
done

# Inject a deterministic chmod error without changing production code.
prepare_case chmod-failure
chmod_fail_path=''
chmod_fail_path=$KA_TARGETS_DIR
rc=0
ka_ensure_runtime_dirs >"$TEST_TMP/chmod-runtime.out" 2>&1 || rc=$?
assert_true 'runtime chmod failure propagates to the caller' test "$rc" -ne 0
assert_contains "$TEST_TMP/chmod-runtime.out" 'could not secure runtime directory' \
    'runtime chmod failure is reported'
chmod_fail_path=''
ka_ensure_runtime_dirs
chmod_fail_path=$KA_CONFIG_DIR
rc=0
ka_ensure_config_dirs >"$TEST_TMP/chmod-config.out" 2>&1 || rc=$?
assert_true 'config chmod failure propagates to the caller' test "$rc" -ne 0
assert_contains "$TEST_TMP/chmod-config.out" 'could not secure configuration directories' \
    'config chmod failure is reported'
unset -f chmod

# Role: Verify both atomic scalar writers reject a directory destination rather than
# silently placing their temporary file inside that directory.
atomic_directory_probe() {
    local label=$1 writer=$2 destination="$TEST_TMP/$1-destination" rc=0 nested
    mkdir -p "$destination"
    printf 'keep\n' >"$destination/sentinel"
    if [[ $writer == value ]]; then
        ka_atomic_write_value "$destination" 'replacement' 2>"$TEST_TMP/$label.err" || rc=$?
    else
        printf 'replacement\n' | ka_atomic_write "$destination" 2>"$TEST_TMP/$label.err" || rc=$?
    fi
    assert_true "$writer atomic writer rejects a directory destination" test "$rc" -ne 0
    assert_true "$writer atomic writer leaves the destination directory" test -d "$destination"
    assert_eq keep "$(<"$destination/sentinel")" \
        "$writer atomic writer leaves existing destination contents unchanged"
    nested=$(directory_entries "$destination")
    assert_eq "$destination/sentinel" "$nested" \
        "$writer atomic writer does not nest a temporary file below the directory"
}

atomic_directory_probe atomic-value value
atomic_directory_probe atomic-stream stream

test_finish
