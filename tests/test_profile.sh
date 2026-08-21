#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core

ka_profile_init_defaults
assert_eq 1500 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'default main interval is 25 minutes'
assert_eq ping "$(ka_read_first_line "$KA_PROFILE_DIR/messages/001")" 'default profile message is ping'

req="$TEST_TMP/request"
ka_profile_copy_to_request "$req"
ka_write_scalar "$req/main_interval" 900
ka_write_scalar "$req/delivery_mode" ENTER_ONLY
ka_write_scalar "$req/messages/001" 'literal $HOME $(touch nope)'
ka_profile_update_from_request "$req"
assert_eq 900 "$(ka_read_first_line "$KA_PROFILE_DIR/main_interval")" 'profile update changes future default interval'
assert_eq ENTER_ONLY "$(ka_read_first_line "$KA_PROFILE_DIR/delivery_mode")" 'profile update changes delivery mode'
assert_eq 'literal $HOME $(touch nope)' "$(ka_read_first_line "$KA_PROFILE_DIR/messages/001")" 'profile stores arbitrary message literally'

test_finish
