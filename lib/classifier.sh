#!/usr/bin/env bash
# AI CLI classifier based on Linux /proc process metadata and ancestry.
# The built-in registry is intentionally data-driven and can be extended through
# ${XDG_CONFIG_HOME:-$HOME/.config}/keepalive/classifiers.tsv without changing service code.

# Role: Initialize the built-in AI CLI signature registry and optional user extensions.
ka_classifier_init() {
    declare -gA KA_CLASS_NAMES=()
    declare -gA KA_CLASS_PATTERNS=()
    declare -ga KA_CLASS_ORDER=()

    # Exact command boundaries reduce false positives from generic process names while
    # package/path signatures still recognize Node/Python wrapper installations.
    ka_classifier_add 'Claude'  '(^|[ /])claude([ /]|$)|@anthropic-ai/claude-code|claude-code'
    ka_classifier_add 'Codex'   '(^|[ /])codex([ /]|$)|@openai/codex|openai-codex'
    ka_classifier_add 'Kimi'    '(^|[ /])kimi([ /]|$)|kimi-cli|kimi-code|moonshot.*kimi'
    ka_classifier_add 'Gemini'  '(^|[ /])gemini([ /]|$)|@google/gemini-cli|gemini-cli'
    ka_classifier_add 'Qwen'    '(^|[ /])qwen([ /]|$)|qwen-code|@qwen-code'
    ka_classifier_add 'OpenCode' '(^|[ /])opencode([ /]|$)|opencode-ai'
    ka_classifier_add 'Aider'   '(^|[ /])aider([ /]|$)|aider-chat'
    ka_classifier_add 'Goose'   '(^|[ /])goose([ /]|$)|block.*goose'
    ka_classifier_add 'GitHub Copilot' '(^|[ /])copilot([ /]|$)|github-copilot|copilot-cli'
    ka_classifier_add 'Amp'     '(^|[ /])amp([ /]|$)|sourcegraph.*amp'
    ka_classifier_add 'Crush'   '(^|[ /])crush([ /]|$)|charmbracelet.*crush'
    ka_classifier_add 'Cody'    '(^|[ /])cody([ /]|$)|sourcegraph.*cody'
    ka_classifier_add 'Plandex' '(^|[ /])plandex([ /]|$)'
    ka_classifier_add 'Mentat'  '(^|[ /])mentat([ /]|$)'
    ka_classifier_add 'Continue' 'continue-cli|continuedev|(^|[ /])continue([ /]|$)'
    ka_classifier_add 'Cline'   'cline-cli|(^|[ /])cline([ /]|$)'
    ka_classifier_add 'Roo'     'roo-code|roo-cli'
    ka_classifier_add 'Amazon Q' 'amazon-q|qchat|amazon.*q.*cli'
    ka_classifier_add 'Warp Agent' 'warp-agent|warp.*agent'
    ka_classifier_add 'Cursor Agent' 'cursor-agent|cursor.*agent'
    ka_classifier_add 'OpenHands' '(^|[ /])openhands([ /]|$)|open-hands'
    ka_classifier_add 'SWE-agent' 'swe-agent|swe_agent'
    ka_classifier_add 'GPT Engineer' 'gpt-engineer|gpt_engineer'
    ka_classifier_add 'Factory Droid' '(^|[ /])droid([ /]|$)|factory.*droid'
    ka_classifier_add 'Junie' '(^|[ /])junie([ /]|$)|junie-cli'
    ka_classifier_add 'Kilo' '(^|[ /])kilo([ /]|$)|kilo-cli'
    ka_classifier_add 'Grok CLI' 'grok-cli|grok.*build'
    ka_classifier_add 'T3 Code' '(^|[ /])t3([ /]|$)|t3-code'
    ka_classifier_add 'ForgeCode' '(^|[ /])forgecode([ /]|$)|forge-code'
    ka_classifier_add 'Antigravity' 'antigravity-cli|(^|[ /])antigravity([ /]|$)'


    ka_classifier_load_user_registry
}

# Role: Add or replace one classifier entry while preserving deterministic ordering.
ka_classifier_add() {
    local name=$1 patterns=$2 key
    ka_safe_id "${name,,}"; key=$REPLY
    if [[ -z ${KA_CLASS_NAMES[$key]+x} ]]; then
        KA_CLASS_ORDER+=("$key")
    fi
    KA_CLASS_NAMES[$key]=$name
    KA_CLASS_PATTERNS[$key]=$patterns
}

# Role: Load optional tab-separated "Name<TAB>regex" classifier additions from config.
ka_classifier_load_user_registry() {
    local path="$KA_CONFIG_DIR/classifiers.tsv"
    [[ -r $path ]] || return 0
    local name patterns line_no=0 probe_rc
    while IFS=$'\t' read -r name patterns _; do
        line_no=$((line_no + 1))
        # A file saved with CRLF endings leaves a carriage return on the last field, which
        # becomes part of the regex and makes the entry silently never match.
        name=${name%$'\r'}
        patterns=${patterns%$'\r'}
        [[ -n $name && -n $patterns ]] || continue
        [[ $name == \#* ]] && continue
        # Reject a pattern that will not compile, rather than registering an entry that can
        # never match and gives the operator nothing to go on. `=~` returns 2 for a bad
        # regex, against 0 or 1 for a decided match.
        probe_rc=0
        # The status of the [[ ]] itself is the point here - 2 means the regex did not
        # compile - so capturing it from a condition is deliberate.
        # shellcheck disable=SC2319
        [[ '' =~ $patterns ]] 2>/dev/null || probe_rc=$?
        if ((probe_rc > 1)); then
            ka_warn "classifiers.tsv line $line_no: '$name' has an invalid regular expression; ignoring it"
            continue
        fi
        ka_classifier_add "$name" "$patterns"
    done <"$path"
}

# Executable paths already resolved, so readlink - the one process the signature still
# needs - runs once per process image rather than on every discovery pass. Keyed by PID and
# start time, which an exec keeps; a hit also requires the same comm/cmdline fingerprint and,
# through a builtin inode comparison, that /proc/PID/exe is still that very file, so an exec
# into another binary is noticed even when it keeps the name and arguments. Cleared
# wholesale when it grows past its bound.
declare -gA KA_PROC_EXE_FP=()
declare -gA KA_PROC_EXE_PATH=()
KA_PROC_EXE_CACHE_MAX=1024

# Role: Put a process cmdline as a single printable string in REPLY without tr or sed.
# Arguments are joined by single spaces and trailing whitespace is trimmed, exactly as the
# former `tr '\0' ' ' | sed` pipeline did, but with builtins only.
ka_proc_cmdline_set() {
    local pid=$1 arg out='' sep=''
    local -a argv=()
    REPLY=''
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cmdline ]] || return 1
    # stderr first: a process exiting mid-read must not reach the journal.
    mapfile -d '' -t argv 2>/dev/null <"/proc/$pid/cmdline" || return 1
    for arg in "${argv[@]}"; do
        out+=$sep$arg
        sep=' '
    done
    REPLY=${out%"${out##*[![:space:]]}"}
}

# Role: Read a process cmdline as a single printable string without invoking ps.
ka_proc_cmdline() {
    ka_proc_cmdline_set "$1" || return 1
    printf '%s' "$REPLY"
}

# Role: Put the short comm name for a process from /proc in REPLY.
ka_proc_comm_set() {
    local pid=$1
    REPLY=''
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/comm ]] || return 1
    IFS= read -r REPLY <"/proc/$pid/comm" || return 1
}

# Role: Read the short comm name for a process from /proc.
ka_proc_comm() {
    ka_proc_comm_set "$1" || return 1
    printf '%s' "$REPLY"
}

# Role: Read the resolved executable basename for a process when procfs permits it.
ka_proc_exe_basename() {
    local exe
    exe=$(ka_proc_exe_path "$1") || return 1
    printf '%s' "${exe##*/}"
}

# Role: Read the resolved executable path for a process when procfs permits it.
ka_proc_exe_path() {
    local pid=$1
    [[ $pid =~ ^[0-9]+$ && -e /proc/$pid/exe ]] || return 1
    readlink "/proc/$pid/exe" 2>/dev/null
}

# Role: Put one numeric /proc/PID/stat field (counted after pid and comm) in REPLY.
# Everything through the final ") " belongs to pid+comm, which may contain spaces.
ka_proc_stat_field_set() {
    local pid=$1 index=$2 stat rest
    REPLY=''
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/stat ]] || return 1
    IFS= read -r stat <"/proc/$pid/stat" || return 1
    rest=${stat##*) }
    # Unquoted on purpose: word splitting is what tokenizes the stat fields.
    # shellcheck disable=SC2086
    set -- $rest
    [[ ${!index:-} =~ ^[0-9]+$ ]] || return 1
    REPLY=${!index}
}

# Role: Put a process's PPID (stat field 4) in REPLY.
ka_proc_ppid_set() {
    ka_proc_stat_field_set "$1" 2
}

# Role: Read PPID from /proc/PID/stat while handling command names containing spaces.
ka_proc_ppid() {
    ka_proc_ppid_set "$1" || return 1
    printf '%s' "$REPLY"
}

# Role: Put the start-time tick field (stat field 22) used to guard against PID reuse in REPLY.
ka_proc_starttime_set() {
    ka_proc_stat_field_set "$1" 20
}

# Role: Read the process start-time tick field used to guard against Linux PID reuse.
ka_proc_starttime() {
    ka_proc_starttime_set "$1" || return 1
    printf '%s' "$REPLY"
}

# Role: Put a normalized searchable process signature from comm, exe, and cmdline in REPLY.
ka_proc_signature_set() {
    local pid=$1 comm='' path='' exe cmd='' key fingerprint cached
    ka_proc_comm_set "$pid" && comm=$REPLY
    ka_proc_cmdline_set "$pid" && cmd=$REPLY
    if ka_proc_starttime_set "$pid"; then
        key="$pid:$REPLY"
        fingerprint="$comm"$'\x1f'"$cmd"
        cached=${KA_PROC_EXE_PATH[$key]-}
        # An empty cached path means procfs refused the link; nothing can be revalidated.
        if [[ -n ${KA_PROC_EXE_FP[$key]+x} && ${KA_PROC_EXE_FP[$key]} == "$fingerprint" ]] \
            && [[ -z $cached || /proc/$pid/exe -ef $cached ]]; then
            path=$cached
        else
            path=$(ka_proc_exe_path "$pid" 2>/dev/null || true)
            if ((${#KA_PROC_EXE_FP[@]} >= KA_PROC_EXE_CACHE_MAX)); then
                KA_PROC_EXE_FP=()
                KA_PROC_EXE_PATH=()
            fi
            KA_PROC_EXE_FP[$key]=$fingerprint
            KA_PROC_EXE_PATH[$key]=$path
        fi
    else
        path=$(ka_proc_exe_path "$pid" 2>/dev/null || true)
    fi
    exe=${path##*/}
    REPLY="${comm,,} ${exe,,} ${cmd,,}"
}

# Role: Build a normalized searchable process signature from comm, exe, and cmdline.
ka_proc_signature() {
    ka_proc_signature_set "$1"
    printf '%s' "$REPLY"
}

# Role: Put "Name<TAB>PID" for one recognized process in REPLY using the signature registry.
ka_classifier_match_pid_set() {
    local pid=$1 signature key pattern
    ka_proc_signature_set "$pid" || return 1
    signature=$REPLY
    for key in "${KA_CLASS_ORDER[@]}"; do
        pattern=${KA_CLASS_PATTERNS[$key]}
        if [[ $signature =~ $pattern ]]; then
            REPLY="${KA_CLASS_NAMES[$key]}"$'\t'"$pid"
            return 0
        fi
    done
    return 1
}

# Role: Classify one specific process using the signature registry.
ka_classifier_match_pid() {
    ka_classifier_match_pid_set "$1" || return 1
    printf '%s\n' "$REPLY"
}

# Role: Put "Name<TAB>PID" for the nearest recognized AI CLI in a process's ancestry in REPLY.
# Runs once per Konsole session per discovery pass, walking every ancestor; each step used
# to cost several forks, which made it discovery's largest cost after the D-Bus calls.
ka_classifier_from_process_tree_set() {
    local pid=$1 depth=0
    while [[ $pid =~ ^[0-9]+$ ]] && ((pid > 1 && depth < 48)); do
        ka_classifier_match_pid_set "$pid" && return 0
        ka_proc_ppid_set "$pid" || break
        [[ $REPLY != "$pid" ]] || break
        pid=$REPLY
        ((depth += 1))
    done
    REPLY=''
    return 1
}

# Role: Walk foreground-process ancestry to find the nearest recognized AI CLI root.
ka_classifier_from_process_tree() {
    ka_classifier_from_process_tree_set "$1" || return 1
    printf '%s\n' "$REPLY"
}

# Role: Test whether a process is the same as or descends from a remembered AI process.
# Runs on every health pass for every Konsole target, so the walk reads /proc with builtins.
ka_process_is_descendant_of() {
    local pid=$1 ancestor=$2 depth=0
    [[ $pid =~ ^[0-9]+$ && $ancestor =~ ^[0-9]+$ ]] || return 1
    while ((pid > 1 && depth < 64)); do
        [[ $pid == "$ancestor" ]] && return 0
        ka_proc_ppid_set "$pid" || break
        [[ $REPLY != "$pid" ]] || break
        pid=$REPLY
        ((depth += 1))
    done
    return 1
}
