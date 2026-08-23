#!/usr/bin/env bash
# Common helpers shared by the Keep Alive service and TUI client.

# Role: Print an error to stderr and record it for the IPC responder.
# Daemon-side validators are the only place that knows *why* an operation failed;
# without this the reason reached the journal and clients got a fixed generic string.
ka_error() {
    KA_LAST_ERROR=$*
    printf 'keepalive: ERROR: %s\n' "$*" >&2
}

# Role: Clear the recorded failure reason before starting a new operation.
ka_error_reset() {
    KA_LAST_ERROR=''
}

# Role: Print a warning message to stderr without terminating the caller.
ka_warn() {
    printf 'keepalive: warning: %s\n' "$*" >&2
}

# Role: Print an informational message to stderr for maintenance/debug commands.
ka_info() {
    printf 'keepalive: %s\n' "$*" >&2
}

# Role: Test whether an executable command is available in PATH.
ka_has_command() {
    command -v "$1" >/dev/null 2>&1
}

# Role: Return a string collapsed to one terminal-safe line for TSV/snapshot output.
ka_single_line() {
    local value=${1-}
    value=${value//$'\n'/ }
    value=${value//$'\r'/ }
    value=${value//$'\t'/ }
    printf '%s' "$value"
}

# Role: Convert an identifier into a conservative filename-safe token.
ka_safe_id() {
    local value=${1-}
    value=${value//[^[:alnum:]_.-]/_}
    printf '%s' "$value"
}

# Role: Generate a request identifier unique enough for one logged-in user session.
ka_request_id() {
    printf '%(%s)T-%s-%04d' -1 "$$" "$((RANDOM % 10000))"
}

# Role: Return current wall-clock epoch seconds using Bash's builtin formatter.
ka_now_epoch() {
    printf '%(%s)T' -1
}

# Role: Read integer monotonic seconds into REPLY from procfs or an injectable clock.
# Sets REPLY rather than printing: the service loop reads this several times a second,
# and a command substitution here cost a fork on every iteration.
ka_now_monotonic() {
    local source=${KEEPALIVE_MONOTONIC_FILE:-/proc/uptime} seconds='' _rest=''
    REPLY=''
    [[ -r $source ]] || return 1
    read -r seconds _rest <"$source" || true
    [[ $seconds =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    REPLY=${seconds%%.*}
}

# Role: Read a millisecond wall timestamp into REPLY for sub-second work budgets.
# /proc/uptime has one-second granularity, too coarse to bound a single discovery pass.
ka_now_ms() {
    local t=${EPOCHREALTIME:-}
    if [[ -z $t ]]; then
        REPLY=$(( ${EPOCHSECONDS:-0} * 1000 ))
        return 0
    fi
    t=${t/[.,]/}
    REPLY=$(( 10#${t%???} ))
}

# Role: Return a compact local timestamp suitable for per-target event history.
ka_now_hms() {
    printf '%(%H:%M:%S)T' -1
}

# Role: Return a full local timestamp suitable for daemon/journal diagnostics.
ka_now_full() {
    printf '%(%F %T)T' -1
}

# Role: Clamp an integer value to an inclusive minimum and maximum.
ka_clamp() {
    local value=$1 min=$2 max=$3
    ((value < min)) && value=$min
    ((value > max)) && value=$max
    printf '%d' "$value"
}

# Names already reported as misconfigured, so one bad value warns once rather than on
# every loop iteration.
declare -gA KA_TUNABLE_WARNED=()

# Role: Read a positive-integer tuning knob into REPLY, falling back on anything invalid.
#
# Interpolating an environment value straight into (( )) is unsafe twice over. A
# non-numeric value such as "abc" is treated as a variable name and aborts the shell under
# `set -u`. A numeric-looking one such as "2s" makes the expression itself fail, and since
# `set -e` is suppressed inside an `if` condition the guarded work then silently never
# runs again - health validation stopping for the life of the daemon, with nothing in the
# log to say so. Every knob goes through here instead.
ka_tunable() {
    local name=$1 fallback=$2 value=${!1:-}
    if ka_is_positive_int "$value"; then
        REPLY=$value
        return 0
    fi
    if [[ -n $value && -z ${KA_TUNABLE_WARNED[$name]+x} ]]; then
        KA_TUNABLE_WARNED[$name]=1
        ka_warn "$name=$value is not a positive integer; using the default of $fallback"
    fi
    REPLY=$fallback
}

# Role: Validate that a value is a non-negative base-10 integer.
ka_is_uint() {
    [[ ${1-} =~ ^[0-9]+$ ]]
}

# Role: Validate that a value is a strictly positive base-10 integer.
ka_is_positive_int() {
    [[ ${1-} =~ ^[1-9][0-9]*$ ]]
}

# Role: Format seconds as MM:SS or HH:MM:SS without external commands.
ka_format_duration() {
    local total=${1:-0}
    ((total < 0)) && total=0
    local h=$((total / 3600))
    local m=$(((total % 3600) / 60))
    local s=$((total % 60))
    if ((h > 0)); then
        printf '%02d:%02d:%02d' "$h" "$m" "$s"
    else
        printf '%02d:%02d' "$m" "$s"
    fi
}

# Role: Write stdin to a file atomically by renaming a same-directory temporary file.
# Private permissions come from the process umask, set once in ka_xdg_init, so this no
# longer forks chmod; the directory check is a builtin test rather than an mkdir fork.
ka_atomic_write() {
    local destination=$1
    local directory base tmp
    directory=${destination%/*}
    base=${destination##*/}
    [[ -d $directory ]] || mkdir -p "$directory"
    tmp="$directory/.${base}.tmp.$$.$RANDOM"
    cat >"$tmp"
    mv -f -- "$tmp" "$destination"
}

# Role: Atomically write a literal string without forking cat or a pipeline.
# Scalar and checkpoint writes are the daemon's most frequent file operations; routing
# them through a pipeline into cat cost several forks each.
ka_atomic_write_value() {
    local destination=$1 content=${2-} directory base tmp
    directory=${destination%/*}
    base=${destination##*/}
    [[ -d $directory ]] || mkdir -p "$directory"
    tmp="$directory/.${base}.tmp.$$.$RANDOM"
    printf '%s' "$content" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$destination"
}

# Role: Replace a directory with a staged copy using renames, rolling back on failure.
#
# POSIX offers no atomic directory swap, so this cannot be a true transaction. What it
# does give is a commit window of two renames instead of the whole copy: previously the
# live directory was removed and then repopulated file by file, so a crash or I/O error
# mid-copy left a partially written rotation in place. A failed second rename restores
# the original. Any interruption between the two renames leaves the directory missing,
# which the checkpoint loader already rejects and quarantines rather than using.
ka_commit_staged_dir() {
    local staged=$1 destination=$2 trash="${2}.trash.$$"
    rm -rf -- "$trash"
    if [[ -e $destination ]]; then
        mv -- "$destination" "$trash" || { rm -rf -- "$staged"; return 1; }
    fi
    if ! mv -- "$staged" "$destination"; then
        [[ -e $trash ]] && mv -- "$trash" "$destination"
        rm -rf -- "$staged"
        return 1
    fi
    rm -rf -- "$trash"
    return 0
}

# Role: Remove staging and rollback directories abandoned by an interrupted write.
ka_cleanup_staged_dirs() {
    local root=$1
    command -v find >/dev/null 2>&1 || return 0
    find "$root" -maxdepth 3 -type d \( -name '*.staged.*' -o -name '*.trash.*' \) \
        -exec rm -rf -- {} + 2>/dev/null || true
    return 0
}

# Role: Read the first line of a file, returning a supplied default when absent.
ka_read_first_line() {
    local path=$1 default=${2-}
    if [[ -r $path ]]; then
        REPLY=''
        # read returns non-zero at EOF when the final line lacks a newline; preserve
        # the successfully captured value instead of treating that status as no data.
        IFS= read -r REPLY <"$path" || true
        printf '%s' "$REPLY"
    else
        printf '%s' "$default"
    fi
}

# Role: Write one scalar value followed by a newline using atomic replacement.
ka_write_scalar() {
    local path=$1 value=${2-}
    ka_atomic_write_value "$path" "$value"$'\n'
}

# Role: Escape one string for embedding in JSON output.
ka_json_escape() {
    local value=${1-}
    value=${value//\\/\\\\}
    value=${value//\"/\\\"}
    value=${value//$'\n'/\\n}
    value=${value//$'\r'/\\r}
    value=${value//$'\t'/\\t}
    value=${value//[[:cntrl:]]/}
    printf '%s' "$value"
}

# Role: Remove every control character from untrusted process labels before rendering.
# The previous version removed only a named handful, despite a comment claiming
# otherwise; [[:cntrl:]] covers all of C0, DEL, and C1 in a UTF-8 locale.
ka_strip_controls() {
    local value=${1-}
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }
    value=${value//$'\t'/ }
    value=${value//[[:cntrl:]]/}
    printf '%s' "$value"
}
