#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
ka_classifier_init

# Role: Override proc metadata inside this test to exercise registry behavior deterministically.
ka_proc_signature_set() {
    KA_PROC_POSITION_PID=${MOCK_PROC_PID-}
    REPLY=$MOCK_SIGNATURE
    KA_PROC_LEGACY_SIGNATURE=$MOCK_SIGNATURE
    KA_PROC_BUILTIN_SIGNATURE=$MOCK_BUILTIN_SIGNATURE
}

# Role: Install one synthetic process record for position-aware classifier assertions.
set_mock_signature() {
    MOCK_SIGNATURE=$1
    MOCK_BUILTIN_SIGNATURE=$2
    MOCK_PROC_PID=''
}

# Role: Build and classify synthetic comm/exe/argv fields without creating a process.
assert_position_match() {
    local expected=$1 comm=$2 path=$3 label=$4 actual
    shift 4
    KA_PROC_POSITION_PID=${MOCK_PROC_PID-}
    KA_PROC_ARGV=("$@")
    ka_classifier_position_signature_set "$comm" "$path"
    MOCK_BUILTIN_SIGNATURE=$KA_PROC_BUILTIN_SIGNATURE
    MOCK_SIGNATURE="${comm,,} ${path##*/} ${KA_PROC_ARGV[*],,}"
    if ka_classifier_match_pid_set 900; then
        actual=${REPLY%%$'\t'*}
    else
        actual=NO_MATCH
    fi
    assert_eq "$expected" "$actual" "$label"
}

set_mock_signature 'node /usr/bin/node /x/@anthropic-ai/claude-code/cli.js' \
    'node /usr/bin/node /x/@anthropic-ai/claude-code/cli.js'
assert_eq $'Claude\t123' "$(ka_classifier_match_pid 123)" 'recognize Claude Node wrapper signature'
set_mock_signature 'node /x/@google/gemini-cli/dist/index.js' \
    'node /usr/bin/node /x/@google/gemini-cli/dist/index.js'
assert_eq $'Gemini\t456' "$(ka_classifier_match_pid 456)" 'recognize Gemini CLI signature'
set_mock_signature 'python /venv/bin/aider --model test' \
    'python /venv/bin/python /venv/bin/aider'
assert_eq $'Aider\t789' "$(ka_classifier_match_pid 789)" 'recognize Aider signature'
set_mock_signature 'node /x/@openai/codex/bin/codex.js' \
    'node /usr/bin/node /x/@openai/codex/bin/codex.js'
assert_eq $'Codex\t790' "$(ka_classifier_match_pid 790)" 'recognize Codex Node wrapper signature'
set_mock_signature 'node /x/@anthropic-ai/claude-code/cli.js' \
    'node /usr/bin/node /x/@anthropic-ai/claude-code/cli.js'
assert_eq $'Claude\t791' "$(ka_classifier_match_pid 791)" 'recognize Claude package wrapper signature'
set_mock_signature 'node /x/@qwen-code/qwen-code/dist/index.js' \
    'node /usr/bin/node /x/@qwen-code/qwen-code/dist/index.js'
assert_eq $'Qwen\t792' "$(ka_classifier_match_pid 792)" 'recognize Qwen package wrapper signature'
set_mock_signature 'bash /usr/bin/bash -c export CLAUDE_PLUGIN_DATA=/home/.claude/plugins/data/codex-openai-codex' \
    'bash /usr/bin/bash bash'
assert_false 'shell environment paths do not create a Codex match' ka_classifier_match_pid 793
set_mock_signature 'bash /usr/bin/bash' 'bash /usr/bin/bash bash'
assert_false 'ordinary shell remains unclassified' ka_classifier_match_pid 111

# Every built-in has a native/versioned form and a Node/nvm package-wrapper form. The
# wrapper paths model npm-global and nvm installs; matching only the selected script path
# prevents later prompt/file arguments from becoming classifiers.
while IFS= read -r corpus_line; do
    [[ -n $corpus_line ]] || continue
    corpus_line=${corpus_line//\\t/$'\t'}
    IFS=$'\t' read -r expected slug package <<<"$corpus_line"
    assert_position_match "$expected" "$slug" "/opt/$slug/versions/1.0/$slug" "native/versioned $expected" \
        "/opt/$slug/versions/1.0/$slug"
    assert_position_match "$expected" node "/home/niel/.local/share/mise/installs/node/24.18.0/bin/node" "nvm/node wrapper $expected" \
        node \
        "/home/niel/.nvm/versions/node/v22.14.0/lib/node_modules/$package/dist/index.js"
done <<'CORPUS'
Claude\tclaude\t@anthropic-ai/claude-code
Codex\tcodex\t@openai/codex
Kimi\tkimi\tkimi-cli
Gemini\tgemini\t@google/gemini-cli
Qwen\tqwen\t@qwen-code/qwen-code
OpenCode\topencode\topencode-ai
Aider\taider\taider-chat
Goose\tgoose\tgoose-ai
GitHub Copilot\tgithub-copilot\tgithub-copilot
Amp\tamp\tamp
Crush\tcrush\tcharmbracelet-crush
Cody\tcody\t@sourcegraph/cody
Plandex\tplandex\tplandex
Mentat\tmentat\tmentat
Continue\tcontinue-cli\tcontinue
Cline\tcline\tcline
Roo\troo-code\troo-code
Amazon Q\tamazon-q\tamazon-q
Warp Agent\twarp-agent\twarp-agent
Cursor Agent\tcursor-agent\tcursor-agent
OpenHands\topenhands\topenhands
SWE-agent\tswe-agent\tswe-agent
GPT Engineer\tgpt-engineer\tgpt-engineer
Factory Droid\tfactory-droid\tfactory-droid
Junie\tjunie\tjunie
Kilo\tkilo\tkilo
Grok CLI\tgrok-cli\tgrok-cli
T3 Code\tt3-code\tt3-code
ForgeCode\tforgecode\tforgecode
Antigravity\tantigravity-cli\tantigravity-cli
CORPUS

# Exercise the launcher grammars and option-value/payload exclusions with realistic argv.
assert_position_match Claude node /nvm/node 'node -r /tmp/claude-hook.js /opt/claude/cli.js' \
    node -r /tmp/claude-hook.js /opt/claude/cli.js
assert_position_match Codex npx /usr/bin/npx 'npx --package @openai/codex codex' \
    npx --package @openai/codex codex
assert_position_match Gemini bunx /usr/bin/bunx 'bunx @google/gemini-cli@latest' \
    bunx @google/gemini-cli@latest
assert_position_match Kimi pnpm /usr/bin/pnpm 'pnpm dlx kimi-cli' \
    pnpm dlx kimi-cli
assert_position_match OpenCode yarn /usr/bin/yarn 'yarn dlx opencode' \
    yarn dlx opencode
assert_position_match Aider python3 /venv/bin/python3 'python3 -m aider' \
    python3 -m aider
assert_position_match Goose uvx /usr/bin/uvx 'uvx goose-ai' \
    uvx goose-ai
assert_position_match Qwen pipx /usr/bin/pipx 'pipx run qwen-code' \
    pipx run qwen-code
assert_position_match Claude env /usr/bin/env 'env NODE_ENV=prod node /opt/claude/cli.js' \
    env NODE_ENV=prod node /opt/claude/cli.js
assert_position_match Claude bash /usr/bin/bash 'bash /opt/claude' \
    bash /opt/claude
assert_position_match Codex npm /usr/bin/npm 'npm exec --package @openai/codex codex' \
    npm exec --package @openai/codex codex

# With a readable cwd, an existing regular file is the only interpreter script identity;
# directories and launcher values are skipped, while mocked metadata keeps the legacy
# fallback above for synthetic paths that cannot be inspected.
file_cwd=$TEST_TMP/classifier-cwd
mkdir -p "$file_cwd/claude" "$file_cwd/diag" "$file_cwd/env-claude" "$file_cwd/watch-claude"
printf '#!/usr/bin/env node\n' > "$file_cwd/claude/entry.js"
printf '#!/usr/bin/env bash\n' > "$file_cwd/claude/entry.sh"
printf 'hook\n' > "$file_cwd/hook.js"
printf 'dotenv\n' > "$file_cwd/.env"
printf 'value\n' > "$file_cwd/bun-env-claude"
printf 'value\n' > "$file_cwd/deno-env-claude"
old_pwd=$PWD
cd "$file_cwd"
MOCK_PROC_PID=$$
assert_position_match Claude node /usr/bin/node 'node diagnostic directory then relative script' \
    node --diagnostic-dir diag claude/entry.js
assert_position_match Claude node /usr/bin/node 'node diagnostic directory then absolute script' \
    node --diagnostic-dir "$file_cwd/diag" "$file_cwd/claude/entry.js"
assert_position_match NO_MATCH node /usr/bin/node 'node diagnostic directory value only' \
    node --diagnostic-dir claude
assert_position_match NO_MATCH node /usr/bin/node 'node diagnostic regular-file value only' \
    node --diagnostic-dir hook.js
assert_position_match NO_MATCH node /usr/bin/node 'unknown option directory is not a script' \
    node --unknown "$file_cwd/claude"
assert_position_match Claude env /usr/bin/env 'env -C then node script' \
    env -C env-claude node claude/entry.js
assert_position_match NO_MATCH env /usr/bin/env 'env -C directory value only' \
    env -C env-claude /bin/true
assert_position_match Claude env /usr/bin/env 'env -S command string then script' \
    env -S 'VAR=1 node claude/entry.js'
assert_position_match NO_MATCH env /usr/bin/env 'env -S shell payload' \
    env -S 'bash -c echo claude'
assert_position_match Claude bun /usr/bin/bun 'bun env-file then script' \
    bun --env-file .env run claude/entry.js
assert_position_match NO_MATCH bun /usr/bin/bun 'bun env-file value only' \
    bun --env-file bun-env-claude
assert_position_match Claude deno /usr/bin/deno 'deno watch-path then script' \
    deno run --watch-path watch-claude claude/entry.js
assert_position_match NO_MATCH deno /usr/bin/deno 'deno watch-path value only' \
    deno run --watch-path deno-env-claude
assert_position_match NO_MATCH npm /usr/bin/npm 'npm --call shell payload' \
    npm exec --call 'echo claude' @openai/codex
assert_position_match NO_MATCH npx /usr/bin/npx 'npx --call shell payload' \
    npx --call 'echo claude' @openai/codex
assert_position_match Claude bash /usr/bin/bash 'bash --norc then relative script' \
    bash --norc claude/entry.sh
MOCK_PROC_PID=''
cd "$old_pwd"

# A command-identifying path is not an arbitrary argument, option value, shell payload, or
# assignment. These are the false-positive forms from DISC-1 plus editor/tool variants.
while IFS= read -r negative_line; do
    [[ -n $negative_line ]] || continue
    negative_line=${negative_line//\\t/$'\t'}
    IFS=$'\t' read -r label comm path argv0 arg1 arg2 arg3 <<<"$negative_line"
    assert_position_match NO_MATCH "$comm" "$path" "$label" "$argv0" "$arg1" "$arg2" "$arg3"
done <<'NEGATIVE'
vim\tvim\t/usr/bin/vim\tvim\t~/src/codex/README.md\t\t
gedit\tgedit\t/usr/bin/gedit\tgedit\t/home/u/claude/notes\t\t
less\tless\t/usr/bin/less\tless\t/home/u/claude/notes\t\t
grep\tgrep\t/usr/bin/grep\tgrep\t/home/u/gemini/config\t\t
tail\ttail\t/usr/bin/tail\ttail\t/home/u/codex/log\t\t
git\tgit\t/usr/bin/git\tgit\t-C\t~/src/gemini\tstatus
bash-c\tbash\t/usr/bin/bash\tbash\t-c\texport FOO=/tmp/claude/config\t
bash-lc\tbash\t/usr/bin/bash\tbash\t-lc\texport FOO=/tmp/claude/config\t
bash-s\tbash\t/usr/bin/bash\tbash\t-s\tclaude\t
env-shell\tenv\t/usr/bin/env\tenv\tFOO=/tmp/codex\tbash\t-c
node-option-value\tnode\t/usr/bin/node\tnode\t--require\t/tmp/codex-hook.js\t/tmp/plain.js
python-payload\tpython3\t/usr/bin/python3\tpython3\t-c\timport claude\t
npx-option-value\tnpx\t/usr/bin/npx\tnpx\t--node-options\t/tmp/codex-hook.js\tplain-package
uvx-option-value\tuvx\t/usr/bin/uvx\tuvx\t--python\t/tmp/claude-env\tplain-tool
pipx-option-value\tpipx\t/usr/bin/pipx\tpipx\trun\t--python\t/tmp/codex-env
NEGATIVE

assert_true 'process is descendant of itself' ka_process_is_descendant_of "$$" "$$"
assert_false 'invalid ancestor relationship rejected' ka_process_is_descendant_of "$$" 99999999

# User classifier entries are hand-edited configuration, so both of these are plausible
# and both used to fail silently.
printf 'Windows\tnotepad\r\nBroken\t[unclosed\nGood\tmytool\nLegacy\tcustom-token\n' > "$KA_CONFIG_DIR/classifiers.tsv"
warn_file="$TEST_TMP/classifier.warn"
ka_classifier_init 2>"$warn_file"
assert_eq 'notepad' "${KA_CLASS_PATTERNS[windows]-}" 'a CRLF line ending is stripped from the pattern'
assert_eq '' "${KA_CLASS_PATTERNS[broken]-}" 'a pattern that cannot compile is not registered'
assert_eq 'mytool' "${KA_CLASS_PATTERNS[good]-}" 'valid entries after a rejected one still load'
assert_contains "$warn_file" 'invalid regular expression' 'the rejected pattern is reported to the operator'
set_mock_signature 'bash /usr/bin/bash bash -c custom-token' 'bash /usr/bin/bash bash'
assert_eq $'Legacy\t901' "$(ka_classifier_match_pid 901)" \
    'user registry entries retain full legacy signature matching'
rm -f "$KA_CONFIG_DIR/classifiers.tsv"

test_finish
