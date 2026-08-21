#!/usr/bin/env bash
# Common helpers shared by the Keep Alive service and TUI client.

# Role: Print an error message to stderr without terminating the caller.
ka_error() {
    printf 'keepalive: ERROR: %s\n' "$*" >&2
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
ka_atomic_write() {
    local destination=$1
    local directory base tmp
    directory=${destination%/*}
    base=${destination##*/}
    mkdir -p "$directory"
    tmp="$directory/.${base}.tmp.$$.$RANDOM"
    cat >"$tmp"
    chmod 600 "$tmp" 2>/dev/null || true
    mv -f -- "$tmp" "$destination"
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
    printf '%s\n' "$value" | ka_atomic_write "$path"
}

# Role: Remove ANSI control characters from untrusted process labels before rendering.
ka_strip_controls() {
    local value=${1-}
    # Keep printable characters and common spaces; Bash pattern removes C0 controls.
    value=${value//$'\e'/}
    value=${value//$'\a'/}
    value=${value//$'\b'/}
    value=${value//$'\f'/}
    value=${value//$'\v'/}
    value=${value//$'\r'/ }
    value=${value//$'\n'/ }
    value=${value//$'\t'/ }
    printf '%s' "$value"
}
