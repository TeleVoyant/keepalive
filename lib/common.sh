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

# Role: Collapse a string to one TSV-safe line in REPLY.
#
# Sets REPLY rather than printing: this is a pure string operation, but every caller
# reached it through a command substitution, which forks. It runs about ten times per
# checkpoint and per index row, and those run once a second per target, so it was one of
# the daemon's largest single costs.
ka_single_line() {
    local value=${1-}
    value=${value//$'\n'/ }
    value=${value//$'\r'/ }
    value=${value//$'\t'/ }
    REPLY=$value
}

# Role: Convert an identifier into a conservative filename-safe token, in REPLY.
# Sets REPLY for the same reason as ka_single_line: it is pure string work that sat behind
# a command substitution on the daemon's per-second paths.
ka_safe_id() {
    local value=${1-}
    value=${value//[^[:alnum:]_.-]/_}
    REPLY=$value
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

# Role: Read monotonic milliseconds into REPLY from the same source as ka_now_monotonic.
# The service loop sleeps until its next deadline, and whole seconds are too coarse to
# compute how long that is. Missing fraction digits read as zero.
ka_now_monotonic_ms() {
    local source=${KEEPALIVE_MONOTONIC_FILE:-/proc/uptime} raw='' _rest='' fraction
    REPLY=''
    [[ -r $source ]] || return 1
    read -r raw _rest <"$source" || true
    # Twelve digits of seconds is over thirty thousand years of uptime and still leaves
    # the millisecond product far inside 64-bit range; anything longer is not a clock.
    [[ $raw =~ ^([0-9]{1,12})([.]([0-9]+))?$ ]] || return 1
    fraction="${BASH_REMATCH[3]}000"
    REPLY=$((10#${BASH_REMATCH[1]} * 1000 + 10#${fraction:0:3}))
}

# Role: Pause for a fractional number of seconds without starting a process per call.
# `read -t` on a private pipe that never receives data times out exactly like sleep. The
# pipe is opened read-write once per process, so it can never report EOF; if it cannot be
# opened, or a read ever returns before its timeout, this falls back to the sleep command.
ka_sleep() {
    local seconds=$1 rc=0 fd
    if [[ -z ${KA_SLEEP_FD:-} ]]; then
        { exec {KA_SLEEP_FD}<> <(:); } 2>/dev/null || KA_SLEEP_FD=-1
    fi
    if [[ $KA_SLEEP_FD != -1 ]]; then
        read -r -t "$seconds" -u "$KA_SLEEP_FD" _ 2>/dev/null || rc=$?
        ((rc > 128)) && return 0
        # The pipe is unusable; release it before falling back for good.
        fd=$KA_SLEEP_FD
        { exec {fd}<&-; } 2>/dev/null || true
        KA_SLEEP_FD=-1
    fi
    sleep "$seconds"
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
    ka_format_duration_set "${1:-0}"
    printf '%s' "$REPLY"
}

# Role: Put seconds formatted as MM:SS or HH:MM:SS in REPLY.
ka_format_duration_set() {
    local total=${1:-0}
    ((total < 0)) && total=0
    local h=$((total / 3600))
    local m=$(((total % 3600) / 60))
    local s=$((total % 60))
    if ((h > 0)); then
        printf -v REPLY '%02d:%02d:%02d' "$h" "$m" "$s"
    else
        printf -v REPLY '%02d:%02d' "$m" "$s"
    fi
}

# Role: Exclusively create a private same-directory temporary file and hold it open.
# Sets KA_ATOMIC_TMP to its path and KA_ATOMIC_FD to a write descriptor on it.
#
# This replaces `$(mktemp)` plus `chmod 600`: three processes per write on the daemon's
# most frequent file operation. noclobber makes the redirection an O_EXCL create, and the
# name carries 64 random bits. Callers write through the held descriptor and never reopen
# the path, so an entry swapped in after creation cannot redirect the write. noclobber
# would still open an existing FIFO or device without O_EXCL - and block on a FIFO - so
# any existing entry is skipped first. The mode comes from the umask 077 that ka_xdg_init
# records; any process that did not go through it still gets an explicit chmod.
ka_atomic_temp() {
    local directory=$1 base=$2 tmp attempt fd restore_noclobber=1
    KA_ATOMIC_TMP=''
    KA_ATOMIC_FD=''
    [[ $- == *C* ]] && restore_noclobber=0
    set -o noclobber
    for attempt in 1 2 3 4 5 6 7 8; do
        tmp="$directory/.${base}.tmp.$$.${SRANDOM:-$RANDOM}${SRANDOM:-$RANDOM}"
        [[ -e $tmp || -L $tmp ]] && continue
        { exec {fd}>"$tmp"; } 2>/dev/null || continue
        ((restore_noclobber == 0)) || set +o noclobber
        # The path must still name the very file this descriptor created.
        if [[ ! -f $tmp || -L $tmp || ! -O $tmp || ! $tmp -ef /dev/fd/$fd ]]; then
            { exec {fd}>&-; } 2>/dev/null || true
            return 1
        fi
        if [[ ${KA_PRIVATE_UMASK:-0} != 1 ]] && ! chmod 600 "$tmp" 2>/dev/null; then
            { exec {fd}>&-; } 2>/dev/null || true
            rm -f -- "$tmp"
            return 1
        fi
        # Not REPLY: callers of the atomic writers may still be holding a REPLY result.
        KA_ATOMIC_TMP=$tmp
        KA_ATOMIC_FD=$fd
        return 0
    done
    ((restore_noclobber == 0)) || set +o noclobber
    return 1
}

# Role: Close the held temporary descriptor and discard the temporary file after a failure.
ka_atomic_abort() {
    local fd=$KA_ATOMIC_FD
    [[ -n $fd ]] && { exec {fd}>&-; } 2>/dev/null
    [[ -n $KA_ATOMIC_TMP ]] && rm -f -- "$KA_ATOMIC_TMP"
    return 1
}

# Role: Close the held temporary descriptor once its content is complete, before the rename.
# Fails when the path no longer names the file that was written: the rename moves a
# pathname, so a swapped-in entry would otherwise be committed in place of our content.
ka_atomic_close() {
    local fd=$KA_ATOMIC_FD tmp=$KA_ATOMIC_TMP
    [[ -f $tmp && ! -L $tmp && $tmp -ef /dev/fd/$fd ]] || return 1
    { exec {fd}>&-; } 2>/dev/null || return 1
    KA_ATOMIC_FD=''
}

# Role: Write stdin to a file atomically by renaming a same-directory temporary file.
# The directory check is a builtin test rather than an mkdir fork.
ka_atomic_write() {
    local destination=$1
    local directory base tmp
    directory=${destination%/*}
    base=${destination##*/}
    [[ -d $directory ]] || mkdir -p -- "$directory" || return 1
    ka_atomic_temp "$directory" "$base" || return 1
    tmp=$KA_ATOMIC_TMP
    cat >&"$KA_ATOMIC_FD" || { ka_atomic_abort; return 1; }
    ka_atomic_close || { ka_atomic_abort; return 1; }
    mv -fT -- "$tmp" "$destination" || { rm -f -- "$tmp"; return 1; }
}

# Role: Atomically write a literal string without forking cat or a pipeline.
# Scalar and checkpoint writes are the daemon's most frequent file operations; the rename
# is now the only process each one starts.
ka_atomic_write_value() {
    local destination=$1 content=${2-} directory base tmp
    directory=${destination%/*}
    base=${destination##*/}
    [[ -d $directory ]] || mkdir -p -- "$directory" || return 1
    ka_atomic_temp "$directory" "$base" || return 1
    tmp=$KA_ATOMIC_TMP
    printf '%s' "$content" >&"$KA_ATOMIC_FD" || { ka_atomic_abort; return 1; }
    ka_atomic_close || { ka_atomic_abort; return 1; }
    # GNU mv normally treats an existing directory as a container, which can turn a
    # malformed scalar path into a false-success write inside that directory. Linux is
    # already a platform requirement and coreutils is a documented dependency, so -T is
    # used to require the destination itself to be replaced.
    mv -fT -- "$tmp" "$destination" || { rm -f -- "$tmp"; return 1; }
}

# Role: Replace a directory with a staged copy using renames, rolling back on failure.
#
# POSIX offers no atomic directory swap, so this cannot be a true transaction. What it
# does give is a commit window of two renames instead of the whole copy: previously the
# live directory was removed and then repopulated file by file, so a crash or I/O error
# mid-copy left a partially written rotation in place. A failed second rename restores
# the original when no concurrent writer has recreated the destination. `mv -T` prevents
# a concurrently recreated directory from silently receiving the staged tree as a child.
# A crash between renames leaves a `.trash.*` directory; persistent profile setup recovers
# a sole valid rollback directory before creating defaults.
ka_commit_staged_dir() {
    local staged=$1 destination=$2 trash had_destination=0
    while :; do
        trash="${destination}.trash.$$.$RANDOM"
        [[ ! -e $trash && ! -L $trash ]] && break
    done
    if [[ -e $destination || -L $destination ]]; then
        had_destination=1
        mv -T -- "$destination" "$trash" || { rm -rf -- "$staged"; return 1; }
    fi
    if ! mv -T -- "$staged" "$destination"; then
        rm -rf -- "$staged" 2>/dev/null || true
        if ((had_destination == 1)); then
            if [[ ! -e $destination && ! -L $destination && (-e $trash || -L $trash) ]] \
                && mv -T -- "$trash" "$destination"; then
                return 1
            fi
            ka_error "could not restore interrupted directory commit for $destination; rollback retained at $trash"
            return 2
        fi
        return 1
    fi
    if ((had_destination == 1)) && ! rm -rf -- "$trash"; then
        # The new directory is already committed. Treat inability to collect the old
        # tree as recoverable debris, not as a failed transaction that callers might
        # incorrectly try to roll back over the live result.
        ka_warn "committed $destination but could not remove stale rollback directory $trash"
    fi
    return 0
}

# Role: Restore the sole rollback directory left when a two-rename commit was interrupted.
ka_recover_staged_dir() {
    local destination=$1
    [[ ! -e $destination && ! -L $destination ]] || return 0
    local -a rollback_dirs=()
    shopt -s nullglob
    rollback_dirs=("$destination".trash.*)
    shopt -u nullglob
    ((${#rollback_dirs[@]} == 0)) && return 0
    if ((${#rollback_dirs[@]} != 1)) \
        || [[ ! -d ${rollback_dirs[0]} || -L ${rollback_dirs[0]} ]]; then
        ka_error "cannot safely recover interrupted directory commit for $destination"
        return 1
    fi
    mv -T -- "${rollback_dirs[0]}" "$destination" \
        || { ka_error "could not recover interrupted directory commit for $destination"; return 1; }
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

# Role: Put an untrusted process label with every control character removed in REPLY.
# The previous version removed only a named handful, despite a comment claiming
# otherwise; [[:cntrl:]] covers all of C0, DEL, and C1 in a UTF-8 locale.
ka_strip_controls_set() {
    local value=${1-}
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }
    value=${value//$'\t'/ }
    REPLY=${value//[[:cntrl:]]/}
}

# Role: Remove every control character from untrusted process labels before rendering.
ka_strip_controls() {
    ka_strip_controls_set "${1-}"
    printf '%s' "$REPLY"
}
