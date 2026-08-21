#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
source "$TEST_ROOT/lib/icons.sh"
source "$TEST_ROOT/lib/tui/screen.sh"
KA_ICONS_ENABLED=0; KA_COLOR_ENABLED=0; KA_ASCII_MODE=1
ka_icons_init; ka_tui_style_init
assert_eq '#####-----' "$(ka_tui_progress 500 1000 10)" 'ASCII timer bar shows remaining-time depletion'
assert_eq '##-------- !' "$(ka_tui_progress 20 100 10)" 'critical timer bar adds urgency marker'
assert_eq 'AVAILABLE' "$(ka_tui_status AVAILABLE)" 'no-icons status remains semantically complete'

test_finish
