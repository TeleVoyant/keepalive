#!/usr/bin/env bash
# AI CLI classifier based on Linux /proc process metadata and ancestry.
# The built-in registry is intentionally data-driven and can be extended through
# ~/.config/keepalive/classifiers.tsv without changing service code.

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
    key=$(ka_safe_id "${name,,}")
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
        [[ '' =~ $patterns ]] 2>/dev/null || probe_rc=$?
        if ((probe_rc > 1)); then
            ka_warn "classifiers.tsv line $line_no: '$name' has an invalid regular expression; ignoring it"
            continue
        fi
        ka_classifier_add "$name" "$patterns"
    done <"$path"
}

# Role: Read a process cmdline as a single printable string without invoking ps.
ka_proc_cmdline() {
    local pid=$1
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cmdline ]] || return 1
    tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null | sed 's/[[:space:]]*$//'
}

# Role: Read the short comm name for a process from /proc.
ka_proc_comm() {
    local pid=$1
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/comm ]] || return 1
    IFS= read -r REPLY <"/proc/$pid/comm" || return 1
    printf '%s' "$REPLY"
}

# Role: Read the resolved executable basename for a process when procfs permits it.
ka_proc_exe_basename() {
    local pid=$1 exe
    [[ $pid =~ ^[0-9]+$ && -e /proc/$pid/exe ]] || return 1
    exe=$(readlink "/proc/$pid/exe" 2>/dev/null) || return 1
    printf '%s' "${exe##*/}"
}

# Role: Read PPID from /proc/PID/stat while handling command names containing spaces.
ka_proc_ppid() {
    local pid=$1 stat rest
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/stat ]] || return 1
    IFS= read -r stat <"/proc/$pid/stat" || return 1
    # Everything through the final ") " belongs to pid+comm; field 4 is then token 2.
    rest=${stat##*) }
    set -- $rest
    [[ ${2:-} =~ ^[0-9]+$ ]] || return 1
    printf '%s' "$2"
}

# Role: Read the process start-time tick field used to guard against Linux PID reuse.
ka_proc_starttime() {
    local pid=$1 stat rest
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/stat ]] || return 1
    IFS= read -r stat <"/proc/$pid/stat" || return 1
    rest=${stat##*) }
    set -- $rest
    # stat field 22 becomes token 20 after removing pid and comm.
    [[ ${20:-} =~ ^[0-9]+$ ]] || return 1
    printf '%s' "${20}"
}

# Role: Build a normalized searchable process signature from comm, exe, and cmdline.
ka_proc_signature() {
    local pid=$1 comm='' exe='' cmd=''
    comm=$(ka_proc_comm "$pid" 2>/dev/null || true)
    exe=$(ka_proc_exe_basename "$pid" 2>/dev/null || true)
    cmd=$(ka_proc_cmdline "$pid" 2>/dev/null || true)
    printf '%s %s %s' "${comm,,}" "${exe,,}" "${cmd,,}"
}

# Role: Classify one specific process using the signature registry.
ka_classifier_match_pid() {
    local pid=$1 signature key pattern
    signature=$(ka_proc_signature "$pid") || return 1
    for key in "${KA_CLASS_ORDER[@]}"; do
        pattern=${KA_CLASS_PATTERNS[$key]}
        if [[ $signature =~ $pattern ]]; then
            printf '%s\t%s\n' "${KA_CLASS_NAMES[$key]}" "$pid"
            return 0
        fi
    done
    return 1
}

# Role: Walk foreground-process ancestry to find the nearest recognized AI CLI root.
ka_classifier_from_process_tree() {
    local pid=$1 depth=0 result parent
    while [[ $pid =~ ^[0-9]+$ ]] && ((pid > 1 && depth < 48)); do
        if result=$(ka_classifier_match_pid "$pid" 2>/dev/null); then
            printf '%s\n' "$result"
            return 0
        fi
        parent=$(ka_proc_ppid "$pid" 2>/dev/null || true)
        [[ $parent =~ ^[0-9]+$ && $parent != "$pid" ]] || break
        pid=$parent
        ((depth += 1))
    done
    return 1
}

# Role: Test whether a process is the same as or descends from a remembered AI process.
ka_process_is_descendant_of() {
    local pid=$1 ancestor=$2 depth=0 parent
    [[ $pid =~ ^[0-9]+$ && $ancestor =~ ^[0-9]+$ ]] || return 1
    while ((pid > 1 && depth < 64)); do
        [[ $pid == "$ancestor" ]] && return 0
        parent=$(ka_proc_ppid "$pid" 2>/dev/null || true)
        [[ $parent =~ ^[0-9]+$ && $parent != "$pid" ]] || break
        pid=$parent
        ((depth += 1))
    done
    return 1
}
