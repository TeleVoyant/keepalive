#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
ka_classifier_init

# Role: Override proc signature inside this test to exercise registry behavior deterministically.
ka_proc_signature_set() { REPLY=$MOCK_SIGNATURE; }
MOCK_SIGNATURE='node /usr/bin/node /x/@anthropic-ai/claude-code/cli.js'
assert_eq $'Claude\t123' "$(ka_classifier_match_pid 123)" 'recognize Claude Node wrapper signature'
MOCK_SIGNATURE='node /x/@google/gemini-cli/dist/index.js'
assert_eq $'Gemini\t456' "$(ka_classifier_match_pid 456)" 'recognize Gemini CLI signature'
MOCK_SIGNATURE='python /venv/bin/aider --model test'
assert_eq $'Aider\t789' "$(ka_classifier_match_pid 789)" 'recognize Aider signature'
MOCK_SIGNATURE='bash /usr/bin/bash'
assert_false 'ordinary shell remains unclassified' ka_classifier_match_pid 111

assert_true 'process is descendant of itself' ka_process_is_descendant_of "$$" "$$"
assert_false 'invalid ancestor relationship rejected' ka_process_is_descendant_of "$$" 99999999

# User classifier entries are hand-edited configuration, so both of these are plausible
# and both used to fail silently.
printf 'Windows\tnotepad\r\nBroken\t[unclosed\nGood\tmytool\n' > "$KA_CONFIG_DIR/classifiers.tsv"
warn_file="$TEST_TMP/classifier.warn"
ka_classifier_init 2>"$warn_file"
assert_eq 'notepad' "${KA_CLASS_PATTERNS[windows]-}" 'a CRLF line ending is stripped from the pattern'
assert_eq '' "${KA_CLASS_PATTERNS[broken]-}" 'a pattern that cannot compile is not registered'
assert_eq 'mytool' "${KA_CLASS_PATTERNS[good]-}" 'valid entries after a rejected one still load'
assert_contains "$warn_file" 'invalid regular expression' 'the rejected pattern is reported to the operator'
rm -f "$KA_CONFIG_DIR/classifiers.tsv"

test_finish
