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

canonical="$TEST_TMP/canonical-request"
ka_profile_copy_to_request "$canonical"
ka_write_scalar "$canonical/messages/002" 'second message'
assert_true 'contiguous 001..N main-message rotation is accepted' ka_profile_validate_request "$canonical"

gap="$TEST_TMP/gapped-request"
ka_profile_copy_to_request "$gap"
mv -- "$gap/messages/001" "$gap/messages/002"
assert_false 'main-message rotation cannot start after 001' ka_profile_validate_request "$gap"

hole="$TEST_TMP/hole-request"
ka_profile_copy_to_request "$hole"
ka_write_scalar "$hole/messages/003" 'third message without second'
assert_false 'main-message rotation cannot contain numbering gaps' ka_profile_validate_request "$hole"

empty="$TEST_TMP/empty-message-request"
ka_profile_copy_to_request "$empty"
ka_atomic_write "$empty/messages/001" </dev/null
assert_false 'main-message rotation rejects empty numbered slots' ka_profile_validate_request "$empty"

test_finish
