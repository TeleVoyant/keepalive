#!/usr/bin/env bash
# AI CLI classifier based on Linux /proc process metadata and ancestry.
# The built-in registry is intentionally data-driven and can be extended through
# ${XDG_CONFIG_HOME:-$HOME/.config}/keepalive/classifiers.tsv without changing service code.

# Role: Initialize the built-in AI CLI token registry and optional user extensions.
ka_classifier_init() {
    declare -gA KA_CLASS_NAMES=()
    declare -gA KA_CLASS_PATTERNS=()
    declare -gA KA_CLASS_MODES=()
    declare -ga KA_CLASS_ORDER=()

    # Built-ins are matched against command-identifying tokens assembled from /proc,
    # never against arbitrary arguments. Package launchers add a normalized name for
    # specs such as @anthropic-ai/claude-code@latest without widening path matching.
    local boundary end package_suffix
    boundary='(^|[ /])'
    end='([ /]|$)'
    package_suffix=''
    ka_classifier_add_builtin 'Claude'  "${boundary}claude${package_suffix}${end}|${boundary}claude[-_]code${package_suffix}${end}|${boundary}@anthropic-ai/claude-code${package_suffix}${end}"
    ka_classifier_add_builtin 'Codex'   "${boundary}codex${package_suffix}${end}|${boundary}codex[-_]cli${package_suffix}${end}|${boundary}@openai/codex${package_suffix}${end}|${boundary}openai[-_]codex${package_suffix}${end}"
    ka_classifier_add_builtin 'Kimi'    "${boundary}kimi${package_suffix}${end}|${boundary}kimi[-_]cli${package_suffix}${end}|${boundary}kimi[-_]code${package_suffix}${end}|${boundary}moonshot[^[:space:]]*kimi${end}"
    ka_classifier_add_builtin 'Gemini'  "${boundary}gemini${package_suffix}${end}|${boundary}gemini[-_]cli${package_suffix}${end}|${boundary}@google/gemini-cli${package_suffix}${end}"
    ka_classifier_add_builtin 'Qwen'    "${boundary}qwen${package_suffix}${end}|${boundary}qwen[-_]code${package_suffix}${end}|${boundary}@qwen-code${package_suffix}${end}"
    ka_classifier_add_builtin 'OpenCode' "${boundary}opencode${package_suffix}${end}|${boundary}opencode-ai${package_suffix}${end}"
    ka_classifier_add_builtin 'Aider'   "${boundary}aider${package_suffix}${end}|${boundary}aider-chat${package_suffix}${end}"
    ka_classifier_add_builtin 'Goose'   "${boundary}goose${package_suffix}${end}|${boundary}goose[-_](ai|cli)${package_suffix}${end}|${boundary}block[^[:space:]]*goose${end}"
    ka_classifier_add_builtin 'GitHub Copilot' "${boundary}copilot${package_suffix}${end}|${boundary}github-copilot${package_suffix}${end}|${boundary}copilot-cli${package_suffix}${end}"
    ka_classifier_add_builtin 'Amp'     "${boundary}amp${package_suffix}${end}|${boundary}sourcegraph[^[:space:]]*amp${end}"
    ka_classifier_add_builtin 'Crush'   "${boundary}crush${package_suffix}${end}|${boundary}charmbracelet[^[:space:]]*crush${end}"
    ka_classifier_add_builtin 'Cody'    "${boundary}cody${package_suffix}${end}|${boundary}sourcegraph[^[:space:]]*cody${end}"
    ka_classifier_add_builtin 'Plandex' "${boundary}plandex${package_suffix}${end}"
    ka_classifier_add_builtin 'Mentat'  "${boundary}mentat${package_suffix}${end}"
    ka_classifier_add_builtin 'Continue' "${boundary}continue-cli${package_suffix}${end}|${boundary}continuedev${package_suffix}${end}|${boundary}continue${package_suffix}${end}"
    ka_classifier_add_builtin 'Cline'   "${boundary}cline-cli${package_suffix}${end}|${boundary}cline${package_suffix}${end}"
    ka_classifier_add_builtin 'Roo'     "${boundary}roo-code${package_suffix}${end}|${boundary}roo-cli${package_suffix}${end}"
    ka_classifier_add_builtin 'Amazon Q' "${boundary}amazon-q${package_suffix}${end}|${boundary}qchat${package_suffix}${end}|${boundary}amazon[^[:space:]]*q[^[:space:]]*cli${end}"
    ka_classifier_add_builtin 'Warp Agent' "${boundary}warp-agent${package_suffix}${end}|${boundary}warp[^[:space:]]*agent${end}"
    ka_classifier_add_builtin 'Cursor Agent' "${boundary}cursor-agent${package_suffix}${end}|${boundary}cursor[^[:space:]]*agent${end}"
    ka_classifier_add_builtin 'OpenHands' "${boundary}openhands${package_suffix}${end}|${boundary}open-hands${package_suffix}${end}"
    ka_classifier_add_builtin 'SWE-agent' "${boundary}swe-agent${package_suffix}${end}|${boundary}swe_agent${package_suffix}${end}"
    ka_classifier_add_builtin 'GPT Engineer' "${boundary}gpt-engineer${package_suffix}${end}|${boundary}gpt_engineer${package_suffix}${end}"
    ka_classifier_add_builtin 'Factory Droid' "${boundary}droid${package_suffix}${end}|${boundary}factory[^[:space:]]*droid${end}"
    ka_classifier_add_builtin 'Junie' "${boundary}junie${package_suffix}${end}|${boundary}junie-cli${package_suffix}${end}"
    ka_classifier_add_builtin 'Kilo' "${boundary}kilo${package_suffix}${end}|${boundary}kilo-cli${package_suffix}${end}"
    ka_classifier_add_builtin 'Grok CLI' "${boundary}grok-cli${package_suffix}${end}|${boundary}grok[^[:space:]]*build${end}"
    ka_classifier_add_builtin 'T3 Code' "${boundary}t3${package_suffix}${end}|${boundary}t3-code${package_suffix}${end}"
    ka_classifier_add_builtin 'ForgeCode' "${boundary}forgecode${package_suffix}${end}|${boundary}forge-code${package_suffix}${end}"
    ka_classifier_add_builtin 'Antigravity' "${boundary}antigravity-cli${package_suffix}${end}|${boundary}antigravity${package_suffix}${end}"

    ka_classifier_load_user_registry
}

# Role: Register a classifier entry with an explicit built-in or legacy matching mode.
ka_classifier_register() {
    local mode name patterns key
    mode=$1
    name=$2
    patterns=$3
    ka_safe_id "${name,,}"
    key=$REPLY
    if [[ -z ${KA_CLASS_NAMES[$key]+x} ]]; then
        KA_CLASS_ORDER+=("$key")
    fi
    KA_CLASS_NAMES[$key]=$name
    KA_CLASS_PATTERNS[$key]=$patterns
    KA_CLASS_MODES[$key]=$mode
}

# Role: Add or replace one user/legacy classifier entry while preserving deterministic ordering.
ka_classifier_add() {
    ka_classifier_register legacy "$1" "$2"
}

# Role: Add one built-in classifier entry matched against position-aware command tokens.
ka_classifier_add_builtin() {
    ka_classifier_register builtin "$1" "$2"
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

declare -ga KA_PROC_ARGV=()
declare -g KA_PROC_LEGACY_SIGNATURE=''
declare -g KA_PROC_BUILTIN_SIGNATURE=''
declare -g KA_PROC_POSITION_COMM=''
declare -g KA_PROC_POSITION_EXE=''
declare -g KA_PROC_POSITION_PID=''
declare -ga KA_PROC_ENV_ARGV=()

# Role: Append a command-identifying token; a path already ends with its basename.
ka_classifier_append_token() {
    local token lower
    token=$1
    lower=${token,,}
    [[ -n $lower ]] || return 0
    if [[ -n $KA_PROC_BUILTIN_SIGNATURE ]]; then
        KA_PROC_BUILTIN_SIGNATURE+=" $lower"
    else
        KA_PROC_BUILTIN_SIGNATURE=$lower
    fi
}

# Role: Append a package spec and its version-free name for simple built-in regexes.
ka_classifier_append_package_token() {
    local token lower scope rest normalized
    token=$1
    ka_classifier_append_token "$token"
    lower=${token,,}
    if [[ $lower == @*/* ]]; then
        scope=${lower%%/*}
        rest=${lower#*/}
        if [[ $rest == *@* ]]; then
            normalized=$scope/${rest%%@*}
            ka_classifier_append_token "$normalized"
        fi
    elif [[ $lower == *@* ]]; then
        normalized=${lower%%@*}
        ka_classifier_append_token "$normalized"
    fi
}

# Role: Map a command argv[0] basename to the launcher grammar used below.
ka_classifier_launcher_kind_set() {
    local path base
    path=$1
    base=${path##*/}
    base=${base,,}
    REPLY=''
    case "$base" in
        node|nodejs) REPLY=node ;;
        python|python3|pypy|pypy3|pypy3.[0-9]*) REPLY=python ;;
        uv) REPLY=uv ;;
        uvx) REPLY=uvx ;;
        pipx) REPLY=pipx ;;
        npx) REPLY=npx ;;
        bun) REPLY=bun ;;
        bunx) REPLY=bunx ;;
        pnpm) REPLY=pnpm ;;
        pnpx) REPLY=pnpx ;;
        yarn|yarnpkg) REPLY=yarn ;;
        npm) REPLY=npm ;;
        corepack) REPLY=corepack ;;
        deno) REPLY=deno ;;
        env) REPLY='env' ;;
        bash|sh|zsh|dash) REPLY=shell ;;
        tsx) REPLY=tsx ;;
        ts-node|ts-node-esm) REPLY=ts-node ;;
    esac
    if [[ -z $REPLY && $base =~ ^python3\.[0-9]+$ ]]; then
        REPLY=python
    fi
}

# Role: Mark a script-launcher option as a payload, a one-word value, or neither.
ka_classifier_script_option_value() {
    local launcher arg
    launcher=$1
    arg=$2
    REPLY=0
    case "$launcher" in
        shell)
            case "$arg" in
                -o|-O|--rcfile|--init-file) REPLY=1 ;;
                --command|--command=*) REPLY=2 ;;
                -c|-c*|-[^-]*c*|-s|-s*) REPLY=2 ;;
            esac
            ;;
        python)
            case "$arg" in
                -c|--command|-c*|--command=*) REPLY=2 ;;
                -W|--warn|-X|--context|-Q|--check-hash-based-pycs) REPLY=1 ;;
            esac
            ;;
        node|tsx|ts-node)
            case "$arg" in
                -e|--eval|-p|--print|-e*|--eval=*|-p*|--print=*) REPLY=2 ;;
                -r|--require|--loader|--import|--conditions|--title|--icu-data-dir|--openssl-config|--redirect-warnings|--test-name-pattern|--test-reporter|--test-reporter-destination|--experimental-loader|--experimental-policy|--input-type|--inspect-port|--watch-path|--tsconfig|--project|--compiler-options|--diagnostic-dir|--cpu-prof-dir|--cpu-prof-name|--heap-prof-dir|--heap-prof-name|--experimental-sea-config|--experimental-config-file|--env-file|--env-file-if-exists|--localstorage-file|--report-dir|--report-filename|--snapshot-blob) REPLY=1 ;;
            esac
            ;;
        bun)
            case "$arg" in
                -e|--eval|-e*|--eval=*) REPLY=2 ;;
                --preload|--define|--smol-file|--target|--jsx|--tsconfig|--env-file|--cwd|--external|--origin|--port|--fetch-preload|--main-fields|--conditions|--drop) REPLY=1 ;;
            esac
            ;;
        deno)
            case "$arg" in
                --config|--import-map|--lock|--cert|--location|--seed|--v8-flags|--inspect|--inspect-brk|--ext|--cwd|--env-file|--watch-path|--filter|--junit-path|--coverage|--jobs) REPLY=1 ;;
                eval|--eval|repl|jupyter) REPLY=2 ;;
            esac
            ;;
    esac
}

# Role: Put file-awareness status for a possible interpreter script in REPLY: 1 is a
# regular file, 2 is a readable process cwd with no regular file, and 3 means that the
# process metadata needed for the check is unavailable, so the legacy positional rule is
# the only safe fallback. The /proc path test does not fork or resolve cwd in the shell.
ka_classifier_script_file_mode_set() {
    local arg pid
    arg=$1
    pid=${KA_PROC_POSITION_PID-}
    REPLY=3
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cwd ]] || return 0
    if [[ $arg == /* ]]; then
        REPLY=2
        [[ -f $arg ]] && REPLY=1
        return 0
    fi
    REPLY=2
    [[ -f /proc/$pid/cwd/$arg ]] && REPLY=1 && return 0
    # A deleted working directory still passes every test above (it is a directory, just
    # unlinked), so a relative script inside it can never be found. Only the link text
    # tells; reading it costs a fork, paid on this miss path alone, never per process.
    local cwd_link
    cwd_link=$(readlink -- "/proc/$pid/cwd" 2>/dev/null) || return 0
    [[ $cwd_link == *' (deleted)' ]] && REPLY=3
    return 0
}

# Role: Mark a package-runner option whose following word is not the package command.
ka_classifier_package_option_value() {
    local arg
    arg=$1
    REPLY=0
    case "$arg" in
        --node-options|--shell|--workspace|--cwd|--directory|--python|--python-version|--with|--with-editable|--index|--index-url|--default-index|--extra-index-url|--find-links|--allow-insecure-host|--config-setting|--project|--env-file|--filter|--reporter|--network-concurrency|--registry|--resolution|--strategy|--cache|--cache-dir|--prefix|--pip-args|--pip-version|--inject|--suffix|-C|-p|-r|-f|-c|-w|-i)
            REPLY=1
            ;;
    esac
}

# Role: Collect the first identifying script/module argument for an interpreter process.
ka_classifier_collect_script_tokens() {
    local launcher start n i arg skip module file_mode
    launcher=$1
    start=$2
    n=${#KA_PROC_ARGV[@]}
    i=$start
    while ((i < n)); do
        arg=${KA_PROC_ARGV[i]}
        if [[ $arg == -- ]]; then
            i=$((i + 1))
            ((i < n)) && ka_classifier_append_token "${KA_PROC_ARGV[i]}"
            return 0
        fi
        if [[ $launcher == python ]]; then
            case "$arg" in
                -m)
                    i=$((i + 1))
                    ((i < n)) && ka_classifier_append_token "${KA_PROC_ARGV[i]}"
                    return 0
                    ;;
                -m?*)
                    module=${arg#-m}
                    ka_classifier_append_token "$module"
                    return 0
                    ;;
                --module=*)
                    module=${arg#--module=}
                    ka_classifier_append_token "$module"
                    return 0
                    ;;
            esac
        fi
        if [[ $arg == -* ]]; then
            ka_classifier_script_option_value "$launcher" "$arg"
            skip=$REPLY
            ((skip == 2)) && return 0
            if ((skip == 1)); then
                i=$((i + 2))
            else
                i=$((i + 1))
            fi
            continue
        fi
        ka_classifier_script_file_mode_set "$arg"
        file_mode=$REPLY
        if ((file_mode == 1 || file_mode == 3)); then
            # A readable cwd lets the file test reject option values and arbitrary names;
            # an unreadable/mocked cwd falls back to the historical first-word behavior.
            ka_classifier_append_token "$arg"
            return 0
        fi
        # The process cwd is readable but this word is not a regular file. Keep looking;
        # an option value such as a directory must not become the script identity.
        i=$((i + 1))
    done
}

# Role: Collect a package spec from npx/bunx/uvx and similar package launchers.
ka_classifier_collect_package_tokens() {
    local start n i arg value skip
    start=$1
    n=${#KA_PROC_ARGV[@]}
    i=$start
    while ((i < n)); do
        arg=${KA_PROC_ARGV[i]}
        if [[ $arg == -- ]]; then
            i=$((i + 1))
            ((i < n)) && ka_classifier_append_package_token "${KA_PROC_ARGV[i]}"
            return 0
        fi
        case "$arg" in
            --call|--call=*)
                # npm/npx --call executes a shell payload, not a package command.
                return 0
                ;;
            --package|--spec|--from)
                i=$((i + 1))
                if ((i < n)); then
                    ka_classifier_append_package_token "${KA_PROC_ARGV[i]}"
                    i=$((i + 1))
                    continue
                fi
                return 0
                ;;
            --package=*|--spec=*|--from=*)
                value=${arg#*=}
                ka_classifier_append_package_token "$value"
                i=$((i + 1))
                continue
                ;;
        esac
        if [[ $arg != -* ]]; then
            ka_classifier_append_package_token "$arg"
            return 0
        fi
        ka_classifier_package_option_value "$arg"
        skip=$REPLY
        if ((skip == 1)); then
            i=$((i + 2))
        else
            i=$((i + 1))
        fi
    done
}

# Role: Find the script or package command following Bun's subcommand.
ka_classifier_collect_bun_tokens() {
    local start n i arg skip
    start=$1
    n=${#KA_PROC_ARGV[@]}
    i=$((start + 1))
    while ((i < n)); do
        arg=${KA_PROC_ARGV[i]}
        case "$arg" in
            x|bunx)
                ka_classifier_collect_package_tokens "$((i + 1))"
                return 0
                ;;
            run|test|build|debug|dev)
                ka_classifier_collect_script_tokens bun "$((i + 1))"
                return 0
                ;;
            install|add|remove|create|pm)
                return 0
                ;;
            --)
                ka_classifier_collect_script_tokens bun "$((i + 1))"
                return 0
                ;;
        esac
        if [[ $arg == -* ]]; then
            ka_classifier_script_option_value bun "$arg"
            skip=$REPLY
            ((skip == 2)) && return 0
            if ((skip == 1)); then
                i=$((i + 2))
            else
                i=$((i + 1))
            fi
        else
            ka_classifier_collect_script_tokens bun "$i"
            return 0
        fi
    done
}

# Role: Find Deno's run/test/compile script while excluding eval payloads and task names.
ka_classifier_collect_deno_tokens() {
    local start n i arg skip
    start=$1
    n=${#KA_PROC_ARGV[@]}
    i=$((start + 1))
    while ((i < n)); do
        arg=${KA_PROC_ARGV[i]}
        case "$arg" in
            run|test|compile|bundle|install)
                ka_classifier_collect_script_tokens deno "$((i + 1))"
                return 0
                ;;
            eval|repl|jupyter|task|fmt|lint|doc|remove|upgrade)
                return 0
                ;;
        esac
        if [[ $arg == -* ]]; then
            ka_classifier_script_option_value deno "$arg"
            skip=$REPLY
            ((skip == 2)) && return 0
            if ((skip == 1)); then
                i=$((i + 2))
            else
                i=$((i + 1))
            fi
        else
            return 0
        fi
    done
}

# Role: Find uv run or uv tool run and collect only its script/package identifier.
ka_classifier_collect_uv_tokens() {
    local start n i arg skip
    start=$1
    n=${#KA_PROC_ARGV[@]}
    i=$((start + 1))
    while ((i < n)); do
        arg=${KA_PROC_ARGV[i]}
        case "$arg" in
            run)
                ka_classifier_collect_script_tokens python "$((i + 1))"
                return 0
                ;;
            tool)
                i=$((i + 1))
                while ((i < n)); do
                    arg=${KA_PROC_ARGV[i]}
                    if [[ $arg == run ]]; then
                        ka_classifier_collect_package_tokens "$((i + 1))"
                        return 0
                    fi
                    if [[ $arg == -* ]]; then
                        ka_classifier_package_option_value "$arg"
                        skip=$REPLY
                        if ((skip == 1)); then
                            i=$((i + 2))
                        else
                            i=$((i + 1))
                        fi
                    else
                        return 0
                    fi
                done
                return 0
                ;;
        esac
        if [[ $arg == -* ]]; then
            ka_classifier_package_option_value "$arg"
            skip=$REPLY
            if ((skip == 1)); then
                i=$((i + 2))
            else
                i=$((i + 1))
            fi
        else
            return 0
        fi
    done
}

# Role: Find pipx run and collect its package spec without scanning later arguments.
ka_classifier_collect_pipx_tokens() {
    local start n i arg skip
    start=$1
    n=${#KA_PROC_ARGV[@]}
    i=$((start + 1))
    while ((i < n)); do
        arg=${KA_PROC_ARGV[i]}
        if [[ $arg == run ]]; then
            ka_classifier_collect_package_tokens "$((i + 1))"
            return 0
        fi
        if [[ $arg == -* ]]; then
            ka_classifier_package_option_value "$arg"
            skip=$REPLY
            if ((skip == 1)); then
                i=$((i + 2))
            else
                i=$((i + 1))
            fi
        else
            return 0
        fi
    done
}

# Role: Find npm exec and collect its package spec while ignoring npm option values.
ka_classifier_collect_npm_tokens() {
    local start n i arg skip
    start=$1
    n=${#KA_PROC_ARGV[@]}
    i=$((start + 1))
    while ((i < n)); do
        arg=${KA_PROC_ARGV[i]}
        if [[ $arg == --call || $arg == --call=* ]]; then
            return 0
        fi
        if [[ $arg == exec || $arg == x ]]; then
            ka_classifier_collect_package_tokens "$((i + 1))"
            return 0
        fi
        if [[ $arg == -* ]]; then
            ka_classifier_package_option_value "$arg"
            skip=$REPLY
            if ((skip == 1)); then
                i=$((i + 2))
            else
                i=$((i + 1))
            fi
        else
            return 0
        fi
    done
}

# Role: Find pnpm dlx or pnpx's package argument while skipping filter values.
ka_classifier_collect_pnpm_tokens() {
    local start n i arg skip
    start=$1
    n=${#KA_PROC_ARGV[@]}
    i=$((start + 1))
    if [[ ${KA_PROC_ARGV[start]##*/} == pnpx ]]; then
        ka_classifier_collect_package_tokens "$i"
        return 0
    fi
    while ((i < n)); do
        arg=${KA_PROC_ARGV[i]}
        if [[ $arg == dlx ]]; then
            ka_classifier_collect_package_tokens "$((i + 1))"
            return 0
        fi
        if [[ $arg == -* ]]; then
            ka_classifier_package_option_value "$arg"
            skip=$REPLY
            if ((skip == 1)); then
                i=$((i + 2))
            else
                i=$((i + 1))
            fi
        else
            return 0
        fi
    done
}

# Role: Find yarn dlx's package argument while skipping unrelated Yarn options.
ka_classifier_collect_yarn_tokens() {
    local start n i arg skip
    start=$1
    n=${#KA_PROC_ARGV[@]}
    i=$((start + 1))
    while ((i < n)); do
        arg=${KA_PROC_ARGV[i]}
        if [[ $arg == dlx ]]; then
            ka_classifier_collect_package_tokens "$((i + 1))"
            return 0
        fi
        if [[ $arg == -* ]]; then
            ka_classifier_package_option_value "$arg"
            skip=$REPLY
            if ((skip == 1)); then
                i=$((i + 2))
            else
                i=$((i + 1))
            fi
        else
            return 0
        fi
    done
}

# Role: Split env's one-word -S command string without invoking a shell or external helper.
ka_classifier_env_split_set() {
    local text char quote='' escaped=0 token='' have=0 i backslash
    text=$1
    backslash=$'\\'
    KA_PROC_ENV_ARGV=()
    for ((i=0; i<${#text}; i++)); do
        char=${text:i:1}
        if ((escaped == 1)); then
            token+=$char
            escaped=0
            have=1
            continue
        fi
        if [[ $quote == "'" ]]; then
            if [[ $char == "'" ]]; then
                quote=''
            else
                token+=$char
            fi
            have=1
            continue
        fi
        if [[ $quote == '"' ]]; then
            if [[ $char == '"' ]]; then
                quote=''
            elif [[ $char == "$backslash" ]]; then
                escaped=1
            else
                token+=$char
            fi
            have=1
            continue
        fi
        if [[ $char == "$backslash" ]]; then
            escaped=1
            have=1
            continue
        fi
        case "$char" in
            "'") quote="'"; have=1 ;;
            '"') quote='"'; have=1 ;;
            [[:space:]])
                if ((have == 1)); then
                    KA_PROC_ENV_ARGV+=("$token")
                    token=''
                    have=0
                fi
                ;;
            *) token+=$char; have=1 ;;
        esac
    done
    ((escaped == 1)) && token+=$backslash
    ((have == 1)) && KA_PROC_ENV_ARGV+=("$token")
}

# Role: Skip env assignments/options and reapply command parsing to the remaining argv.
ka_classifier_collect_env_tokens() {
    local start depth n i arg skip value
    local -a saved_argv=()
    start=$1
    depth=$2
    n=${#KA_PROC_ARGV[@]}
    i=$((start + 1))
    while ((i < n)); do
        arg=${KA_PROC_ARGV[i]}
        if [[ $arg == -- ]]; then
            i=$((i + 1))
            break
        fi
        if [[ $arg == -S || $arg == --split-string ]]; then
            i=$((i + 1))
            if ((i < n)); then
                ka_classifier_env_split_set "${KA_PROC_ARGV[i]}"
                saved_argv=("${KA_PROC_ARGV[@]}")
                KA_PROC_ARGV=(env "${KA_PROC_ENV_ARGV[@]}")
                ka_classifier_collect_env_tokens 0 "$depth"
                KA_PROC_ARGV=("${saved_argv[@]}")
            fi
            return 0
        fi
        if [[ $arg == -S\ * ]]; then
            value=${arg#-S }
            ka_classifier_env_split_set "$value"
            saved_argv=("${KA_PROC_ARGV[@]}")
            KA_PROC_ARGV=(env "${KA_PROC_ENV_ARGV[@]}")
            ka_classifier_collect_env_tokens 0 "$depth"
            KA_PROC_ARGV=("${saved_argv[@]}")
            return 0
        fi
        if [[ $arg == --split-string=* ]]; then
            value=${arg#*=}
            ka_classifier_env_split_set "$value"
            saved_argv=("${KA_PROC_ARGV[@]}")
            KA_PROC_ARGV=(env "${KA_PROC_ENV_ARGV[@]}")
            ka_classifier_collect_env_tokens 0 "$depth"
            KA_PROC_ARGV=("${saved_argv[@]}")
            return 0
        fi
        if [[ $arg == -u || $arg == --unset || $arg == --chdir || $arg == -C || $arg == --argv0 ]]; then
            i=$((i + 2))
            continue
        fi
        if [[ $arg == --unset=* || $arg == --chdir=* || $arg == --argv0=* ]]; then
            i=$((i + 1))
            continue
        fi
        if [[ $arg == -* ]]; then
            i=$((i + 1))
            continue
        fi
        if [[ $arg =~ ^[a-zA-Z_][a-zA-Z0-9_]*= ]]; then
            i=$((i + 1))
            continue
        fi
        break
    done
    ((i < n)) && ka_classifier_collect_command_tokens "$i" "$depth"
}

# Role: Add an argv[0] token and parse only the identifying launcher argument positions.
ka_classifier_collect_command_tokens() {
    local index depth arg launcher
    index=$1
    depth=$2
    launcher=${3-}
    ((depth < 4 && index < ${#KA_PROC_ARGV[@]})) || return 0
    arg=${KA_PROC_ARGV[index]}
    if [[ $arg != "$KA_PROC_POSITION_COMM" && $arg != "$KA_PROC_POSITION_EXE" ]]; then
        ka_classifier_append_token "$arg"
    fi
    if [[ -z $launcher ]]; then
        ka_classifier_launcher_kind_set "$arg"
        launcher=$REPLY
    fi
    case "$launcher" in
        env) ka_classifier_collect_env_tokens "$index" "$((depth + 1))" ;;
        node|nodejs|python|shell|tsx|ts-node) ka_classifier_collect_script_tokens "$launcher" "$((index + 1))" ;;
        bun) ka_classifier_collect_bun_tokens "$index" ;;
        bunx|npx|uvx) ka_classifier_collect_package_tokens "$((index + 1))" ;;
        uv) ka_classifier_collect_uv_tokens "$index" ;;
        pipx) ka_classifier_collect_pipx_tokens "$index" ;;
        npm) ka_classifier_collect_npm_tokens "$index" ;;
        pnpm|pnpx) ka_classifier_collect_pnpm_tokens "$index" ;;
        yarn) ka_classifier_collect_yarn_tokens "$index" ;;
        deno) ka_classifier_collect_deno_tokens "$index" ;;
        corepack) ka_classifier_collect_env_tokens "$index" "$((depth + 1))" ;;
    esac
}

# Role: Build the position-aware built-in signature from comm, exe, and selected argv fields.
ka_classifier_position_signature_set() {
    local comm path argv0 launcher
    comm=$1
    path=$2
    KA_PROC_POSITION_COMM=$comm
    KA_PROC_POSITION_EXE=$path
    KA_PROC_BUILTIN_SIGNATURE=''
    ka_classifier_append_token "$comm"
    ka_classifier_append_token "$path"
    if ((${#KA_PROC_ARGV[@]} > 0)); then
        argv0=${KA_PROC_ARGV[0]}
        ka_classifier_launcher_kind_set "$argv0"
        launcher=$REPLY
        if [[ -n $launcher ]]; then
            ka_classifier_collect_command_tokens 0 0 "$launcher"
        elif [[ $argv0 != "$comm" && $argv0 != "$path" ]]; then
            ka_classifier_append_token "$argv0"
        fi
    fi
    REPLY=$KA_PROC_BUILTIN_SIGNATURE
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

# Role: Put a normalized legacy signature and a position-aware built-in signature in globals.
ka_proc_signature_set() {
    local pid comm path exe cmd sep key fingerprint cached arg
    local -a argv=()
    pid=$1
    REPLY=''
    KA_PROC_ARGV=()
    KA_PROC_LEGACY_SIGNATURE=''
    KA_PROC_BUILTIN_SIGNATURE=''
    KA_PROC_POSITION_PID=''
    [[ $pid =~ ^[0-9]+$ && -r /proc/$pid/cmdline ]] || return 1
    # Read argv once: the same array supplies the legacy display signature and the
    # position-aware collector, avoiding one procfs read and all per-process forks.
    mapfile -d '' -t argv 2>/dev/null <"/proc/$pid/cmdline" || return 1
    KA_PROC_ARGV=("${argv[@]}")
    comm=''
    IFS= read -r comm <"/proc/$pid/comm" 2>/dev/null || true
    cmd=''
    sep=''
    for arg in "${argv[@]}"; do
        cmd+=$sep$arg
        sep=' '
    done
    cmd=${cmd%"${cmd##*[![:space:]]}"}
    path=''
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
    KA_PROC_LEGACY_SIGNATURE="${comm,,} ${exe,,} ${cmd,,}"
    KA_PROC_POSITION_PID=$pid
    ka_classifier_position_signature_set "$comm" "$path"
    REPLY=$KA_PROC_LEGACY_SIGNATURE
}

# Role: Build a normalized searchable process signature from comm, exe, and cmdline.
ka_proc_signature() {
    ka_proc_signature_set "$1"
    printf '%s' "$REPLY"
}

# Role: Put "Name<TAB>PID" for one process using position-aware built-ins and legacy user regexes.
ka_classifier_match_pid_set() {
    local pid signature builtin_signature key
    pid=$1
    KA_PROC_LEGACY_SIGNATURE=''
    KA_PROC_BUILTIN_SIGNATURE=''
    ka_proc_signature_set "$pid" || return 1
    signature=${KA_PROC_LEGACY_SIGNATURE:-$REPLY}
    builtin_signature=${KA_PROC_BUILTIN_SIGNATURE-}
    for key in "${KA_CLASS_ORDER[@]}"; do
        if [[ ${KA_CLASS_MODES[$key]-legacy} == builtin ]]; then
            [[ $builtin_signature =~ ${KA_CLASS_PATTERNS[$key]} ]] || continue
        else
            [[ $signature =~ ${KA_CLASS_PATTERNS[$key]} ]] || continue
        fi
        REPLY="${KA_CLASS_NAMES[$key]}"$'\t'"$pid"
        return 0
    done
    REPLY=''
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
