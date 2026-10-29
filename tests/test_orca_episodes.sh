#!/usr/bin/env bash
# Orca live-health pacing, discovery stamps, and service discovery episodes.
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup
source_core
source "$TEST_ROOT/lib/service.sh"

clock_file="$TEST_TMP/monotonic"
export KEEPALIVE_MONOTONIC_FILE="$clock_file"

# Role: Set the deterministic monotonic source used by cadence and rollback assertions.
set_clock() {
    local value=$1
    printf '%s\n' "$value" >"$clock_file"
}

# Role: Rebuild one minimal monitored Orca target without relying on provider JSON.
reset_orca_target() {
    ka_state_init_arrays
    ORCA_UUID='orca-runtime-health-inc'
    KA_T_UUIDS=("$ORCA_UUID")
    KA_T_BACKEND[$ORCA_UUID]=orca
    KA_T_STATUS[$ORCA_UUID]=ACTIVE
    KA_T_ORCA_HANDLE[$ORCA_UUID]='term-health'
    KA_T_ORCA_PTY[$ORCA_UUID]='pty-health'
    KA_T_ORCA_INCARNATION[$ORCA_UUID]='inc-health'
    KA_T_ORCA_WORKTREE[$ORCA_UUID]='worktree-health'
    KA_T_ORCA_RUNTIME[$ORCA_UUID]='runtime-health'
    KA_T_ORCA_HOST[$ORCA_UUID]='host-health'
    KA_T_ORCA_TAB[$ORCA_UUID]='tab-health'
    KA_T_ORCA_LEAF[$ORCA_UUID]='leaf-health'
    KA_T_ORCA_AGENT[$ORCA_UUID]=codex
    KA_T_STRIKES[$ORCA_UUID]=0
    KA_T_LAST_SEEN[$ORCA_UUID]=initial-last-seen
    KA_T_REASON[$ORCA_UUID]=''
    KA_D_UUIDS=()
    KA_DISCOVERY_STAMP_ORCA=0
    KA_ORCA_LIVE_HEALTH_AT=0
}

# Role: Count one backend validation and return the injected Orca result code.
ka_transport_validate_target() {
    ORCA_VALIDATE_CALLS=$((ORCA_VALIDATE_CALLS + 1))
    return "${ORCA_VALIDATE_RC:-0}"
}

# Role: Complete the state transition without filesystem setup so strike semantics stay focused.
ka_state_mark_unavailable() {
    local uuid=$1 reason=$2
    KA_T_STATUS[$uuid]=UNAVAILABLE
    KA_T_REASON[$uuid]=$reason
    KA_T_STRIKES[$uuid]=0
    return 0
}

# Role: Emit a deterministic Orca adapter stream for state refresh marker handling.
ka_orca_discover() {
    if [[ ${ORCA_DISCOVERY_MODE:-complete} == fail ]]; then
        printf '#INCOMPLETE\tschema:row-type\n'
    else
        printf '#SKIPPED\t1\tpty-less\n#COMPLETE\n'
    fi
}

reset_orca_target
export KEEPALIVE_ORCA_LIVE_HEALTH_INTERVAL=10 KEEPALIVE_VALIDATION_STRIKES=3
ORCA_VALIDATE_CALLS=0 ORCA_VALIDATE_RC=0
set_clock 100
ka_state_validate_targets
assert_eq 1 "$ORCA_VALIDATE_CALLS" 'the first unusable Orca snapshot performs one live health check'
assert_eq 100 "$KA_ORCA_LIVE_HEALTH_AT" 'a live Orca health check stamps its monotonic time'
first_seen=${KA_T_LAST_SEEN[$ORCA_UUID]}

ORCA_VALIDATE_RC=23
set_clock 105
ka_state_validate_targets
assert_eq 1 "$ORCA_VALIDATE_CALLS" 'an Orca health check inside its floor is skipped'
assert_eq 0 "${KA_T_STRIKES[$ORCA_UUID]}" 'a paced-away check does not add a reachability strike'
assert_eq "$first_seen" "${KA_T_LAST_SEEN[$ORCA_UUID]}" 'a paced-away check does not change last-seen metadata'

set_clock 110
ka_state_validate_targets
assert_eq 2 "$ORCA_VALIDATE_CALLS" 'an Orca health check runs again when its floor elapses'
assert_eq 1 "${KA_T_STRIKES[$ORCA_UUID]}" 'missing agent identity consumes the first periodic strike'
set_clock 120
ORCA_VALIDATE_RC=24
ka_state_validate_targets
assert_eq 2 "${KA_T_STRIKES[$ORCA_UUID]}" 'missing PTY consumes the second periodic strike'
set_clock 130
ORCA_VALIDATE_RC=23
ka_state_validate_targets
assert_eq UNAVAILABLE "${KA_T_STATUS[$ORCA_UUID]}" 'repeated code 23/24 results reach UNAVAILABLE at the strike limit'
assert_contains <(printf '%s' "${KA_T_REASON[$ORCA_UUID]}") 'consecutive attempts' \
    'the sticky-unavailable reason records the consecutive transient count'

reset_orca_target
ORCA_VALIDATE_CALLS=0 ORCA_VALIDATE_RC=22
set_clock 140
ka_state_validate_targets
assert_eq 1 "$ORCA_VALIDATE_CALLS" 'schema code 22 still performs the due live check'
assert_eq 0 "${KA_T_STRIKES[$ORCA_UUID]}" 'schema code 22 never consumes identity-loss strikes'
assert_eq ACTIVE "${KA_T_STATUS[$ORCA_UUID]}" 'schema code 22 leaves the target ACTIVE'

reset_orca_target
ORCA_VALIDATE_CALLS=0 ORCA_VALIDATE_RC=0
KA_ORCA_LIVE_HEALTH_AT=150
set_clock 140
ka_state_validate_targets
assert_eq 1 "$ORCA_VALIDATE_CALLS" 'a monotonic rollback makes an ahead health stamp unusable'
assert_eq 140 "$KA_ORCA_LIVE_HEALTH_AT" 'rollback-safe health validation reanchors its stamp'
set_clock 145
ka_state_validate_targets
assert_eq 1 "$ORCA_VALIDATE_CALLS" 'the reanchored health stamp still enforces its floor'
set_clock 145
ka_state_validate_targets live
assert_eq 2 "$ORCA_VALIDATE_CALLS" 'explicit REFRESH live validation bypasses the health floor'
assert_eq 145 "$KA_ORCA_LIVE_HEALTH_AT" 'the explicit live check records its current monotonic time'

reset_orca_target
KA_T_BACKEND[$ORCA_UUID]=konsole
ORCA_VALIDATE_CALLS=0 ORCA_VALIDATE_RC=0
KA_ORCA_LIVE_HEALTH_AT=200
set_clock 205
ka_state_validate_targets
assert_eq 1 "$ORCA_VALIDATE_CALLS" 'the Orca health floor never paces Konsole validation'
assert_eq 200 "$KA_ORCA_LIVE_HEALTH_AT" 'a Konsole-only health pass does not move the Orca stamp'

reset_orca_target
ORCA_VALIDATE_CALLS=0 ORCA_VALIDATE_RC=0
KA_ORCA_LIVE_HEALTH_AT=300
set_clock 305
assert_true 'pre-send validation remains live despite the Orca health floor' \
    ka_scheduler_validate_before_send "$ORCA_UUID"
assert_true 'a second pre-send validation remains unpaced' ka_scheduler_validate_before_send "$ORCA_UUID"
assert_eq 2 "$ORCA_VALIDATE_CALLS" 'pre-send validation invokes the live adapter on every send'
assert_eq 300 "$KA_ORCA_LIVE_HEALTH_AT" 'pre-send validation does not consume periodic health pacing state'

# Refresh stamps every attempt before the adapter stream is consumed, including a skipped-row
# complete pass and a schema-incomplete pass. The adapter is stubbed so this remains jq-free.
KEEPALIVE_ORCA_ENABLED=1
KA_ORCA_DISCOVERY_ATTEMPT_AT=0
ORCA_DISCOVERY_MODE=complete
set_clock 200
assert_true 'a complete Orca refresh accepts skipped rows' ka_state_refresh_orca_discovery
assert_eq 200 "$KA_ORCA_DISCOVERY_ATTEMPT_AT" 'a complete Orca discovery stamps its attempt'
assert_eq '1 (pty-less)' "$KA_ORCA_DISCOVERY_SKIPPED" 'state retains the adapter skipped-row summary'
ORCA_DISCOVERY_MODE=fail
set_clock 201
assert_false 'a schema-incomplete Orca refresh keeps the previous snapshot' ka_state_refresh_orca_discovery
assert_eq 201 "$KA_ORCA_DISCOVERY_ATTEMPT_AT" 'a failed Orca discovery also stamps its attempt'

EPISODE_LOG="$TEST_TMP/orca-episodes.log"
: >"$EPISODE_LOG"

# Role: Capture operator-facing warning lines without invoking journald during unit tests.
ka_warn() {
    printf 'WARN\t%s\n' "$*" >>"$EPISODE_LOG"
}

# Role: Capture operator-facing informational lines without invoking journald during unit tests.
ka_info() {
    printf 'INFO\t%s\n' "$*" >>"$EPISODE_LOG"
}

# Role: Reset the service episode state and select only Orca for reporting assertions.
reset_episode() {
    : >"$EPISODE_LOG"
    KA_CLIENT_PRESENT=1
    KA_KONSOLE_ENABLED=0
    KA_ORCA_ENABLED=1
    KA_SVC_DISCOVER=(orca)
    KA_DISCOVERY_STALE_BACKENDS=Orca
    KA_ORCA_DISCOVERY_FAILURE=''
    KA_ORCA_DISCOVERY_WARNED_REASON=''
    KA_ORCA_DISCOVERY_WARNED_AT=0
    KA_ORCA_DISCOVERY_SKIPPED=''
    KA_ORCA_DISCOVERY_SKIPPED_LOGGED=''
    KA_ORCA_FAILED_PASSES=0
    KA_ORCA_FAILURES=0
    KA_ORCA_RETRY_AT=0
    KA_ORCA_DISCOVERY_ATTEMPT_AT=0
    KEEPALIVE_ORCA_DISCOVERY_INTERVAL=1
}

# Role: Count captured lines containing one exact operator-visible phrase.
episode_count() {
    local phrase=$1
    awk -v phrase="$phrase" 'index($0, phrase) { count += 1 } END { print count + 0 }' "$EPISODE_LOG"
}

reset_episode
KA_ORCA_DISCOVERY_FAILURE='schema:row-type'
KA_DISCOVERY_STAMP_ORCA=90
ka_service_note_orca_discovery 100
ka_service_report_discovery 100
assert_eq 1 "$(episode_count 'Orca discovery did not complete')" 'a failed Orca episode warns once when it starts'
assert_contains "$EPISODE_LOG" 'reason=schema:row-type; snapshot_age=10s; next_retry_in=2s' \
    'the first Orca warning carries reason, snapshot age, and retry delay'
ka_service_note_orca_discovery 101
ka_service_report_discovery 101
assert_eq 1 "$(episode_count 'Orca discovery did not complete')" 'an unchanged Orca failure stays quiet on the next pass'

KA_ORCA_DISCOVERY_FAILURE='schema:truncated'
ka_service_note_orca_discovery 102
ka_service_report_discovery 102
assert_eq 2 "$(episode_count 'Orca discovery did not complete')" 'a changed Orca failure reason warns immediately'
KA_ORCA_DISCOVERY_FAILURE='schema:truncated'
ka_service_note_orca_discovery 1002
ka_service_report_discovery 1002
assert_eq 3 "$(episode_count 'Orca discovery did not complete')" 'an unchanged Orca failure warns again at the reminder interval'

KA_ORCA_DISCOVERY_FAILURE=''
ka_service_discovery_backends 1003
assert_eq 1 "$(episode_count 'Orca discovery recovered after')" \
    'a successful periodic pass closes the Orca episode exactly once'
assert_eq 0 "$KA_ORCA_FAILED_PASSES" 'closing an Orca episode resets the uncapped failed-pass count'
assert_eq '' "$KA_ORCA_DISCOVERY_WARNED_REASON" 'closing an Orca episode clears its warning reason'

# A successful client REFRESH clears the adapter failure; the next periodic selector call
# must close the old episode before planning another pass.
reset_episode
KA_ORCA_DISCOVERY_FAILURE='offline'
ka_service_note_orca_discovery 2000
ka_service_report_discovery 2000
KA_ORCA_DISCOVERY_FAILURE=''
ka_service_discovery_backends 2001
assert_eq 1 "$(episode_count 'Orca discovery recovered after')" \
    'a successful client refresh is reported on the next periodic discovery selection'

reset_episode
KA_ORCA_DISCOVERY_SKIPPED='1 (pty-less)'
ka_service_report_discovery 3000
assert_eq 1 "$(episode_count 'Orca discovery skipped agent rows it cannot bind safely')" \
    'a skipped-row summary is logged when its set first appears'
ka_service_report_discovery 3001
assert_eq 1 "$(episode_count 'Orca discovery skipped agent rows it cannot bind safely')" \
    'an unchanged skipped-row set is not repeated every pass'
KA_ORCA_DISCOVERY_SKIPPED='2 (other-pane)'
ka_service_report_discovery 3002
assert_eq 2 "$(episode_count 'Orca discovery skipped agent rows it cannot bind safely')" \
    'a changed skipped-row set is logged immediately'
KA_ORCA_DISCOVERY_SKIPPED=''
ka_service_report_discovery 3003
assert_eq 1 "$(episode_count 'Orca discovery no longer skips any agent rows')" \
    'clearing skipped rows logs one recovery summary'

KA_SVC_DISCOVER=()
KA_DISCOVERY_STALE_BACKENDS=Orca
KA_ORCA_DISCOVERY_FAILURE='schema:row-type'
ka_service_report_discovery 4000
assert_eq 0 "$(episode_count 'Orca discovery did not complete')" \
    'a backend not attempted in this pass is not judged by the reporter'

reset_episode
KA_SVC_DISCOVER=(konsole)
KA_DISCOVERY_STALE_BACKENDS=Konsole
KA_KONSOLE_DISCOVERY_WARNED=0
ka_service_report_discovery 5000
ka_service_report_discovery 5001
assert_eq 1 "$(episode_count 'Konsole discovery did not complete')" \
    'Konsole failure warns once per episode'
KA_DISCOVERY_STALE_BACKENDS=''
ka_service_report_discovery 5002
assert_eq 1 "$(episode_count 'Konsole discovery recovered')" \
    'Konsole recovery is logged once at the end of its episode'

test_finish
