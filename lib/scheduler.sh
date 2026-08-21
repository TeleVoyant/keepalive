#!/usr/bin/env bash
# Multi-target countdown scheduler and delivery semantics.

# Role: Validate a target immediately before input injection, marking it unavailable on failure.
ka_scheduler_validate_before_send() {
    local uuid=$1 rc reason
    [[ ${KA_T_STATUS[$uuid]-} != UNAVAILABLE ]] || return 1
    if ka_konsole_validate_target "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" "$uuid" \
        "${KA_T_TERM_PID[$uuid]}" "${KA_T_AI_PID[$uuid]}" "${KA_T_AI_START[$uuid]}"; then
        return 0
    fi
    rc=$?
    reason=$(ka_konsole_validation_reason "$rc")
    ka_state_mark_unavailable "$uuid" "$reason"
    return 1
}

# Role: Deliver one MAIN event using the selected target's current mode and message rotation.
ka_scheduler_send_main() {
    local uuid=$1 origin=${2:-AUTO} count index message detail delivery_failed=0
    ka_state_has_target "$uuid" || return 1
    [[ ${KA_T_STATUS[$uuid]} == ACTIVE || $origin == MANUAL ]] || return 2
    ka_scheduler_validate_before_send "$uuid" || return 3

    count=$(ka_state_message_count "$uuid")
    ((count > 0)) || { ka_state_mark_unavailable "$uuid" 'No main messages remain in target state'; return 4; }
    index=${KA_T_MAIN_INDEX[$uuid]}
    ((index >= 0 && index < count)) || index=0
    message=$(ka_state_message_at "$uuid" "$index")

    if [[ ${KA_T_MODE[$uuid]} == ENTER_ONLY ]]; then
        detail='[ENTER]'
    else
        detail=$message
    fi

    if ka_konsole_deliver "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" "${KA_T_MODE[$uuid]}" "$message"; then
        ka_log_event "$uuid" MAIN "$detail" "$([[ $origin == MANUAL ]] && printf 'SENT · manual' || printf SENT)"
        ka_notify_sent "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
        # ENTER_ONLY intentionally does not consume a queued message because no message was sent.
        if [[ ${KA_T_MODE[$uuid]} == MESSAGE_ENTER ]]; then
            KA_T_MAIN_INDEX[$uuid]=$(((index + 1) % count))
        fi
    else
        ka_log_event "$uuid" MAIN "$detail" "$([[ $origin == MANUAL ]] && printf 'FAILED · manual' || printf FAILED)"
        ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
        delivery_failed=1
    fi
    KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
    ka_state_save_target "$uuid" || return
    # A failed transport attempt still consumes this timer event, but callers must
    # receive failure rather than an incorrect IPC success response.
    ((delivery_failed == 0)) || return 5
}

# Role: Deliver one SECONDARY event while preserving the main countdown exactly.
ka_scheduler_send_secondary() {
    local uuid=$1 origin=${2:-AUTO} message detail delivery_failed=0
    ka_state_has_target "$uuid" || return 1
    [[ ${KA_T_SECONDARY_ENABLED[$uuid]} == 1 ]] || return 2
    [[ ${KA_T_STATUS[$uuid]} == ACTIVE || $origin == MANUAL ]] || return 3
    ka_scheduler_validate_before_send "$uuid" || return 4

    message=${KA_T_SECONDARY_MESSAGE[$uuid]}
    if [[ ${KA_T_MODE[$uuid]} == ENTER_ONLY ]]; then detail='[ENTER]'; else detail=$message; fi

    if ka_konsole_deliver "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" "${KA_T_MODE[$uuid]}" "$message"; then
        ka_log_event "$uuid" SECONDARY "$detail" "$([[ $origin == MANUAL ]] && printf 'SENT · manual' || printf SENT)"
        ka_notify_sent "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
    else
        ka_log_event "$uuid" SECONDARY "$detail" "$([[ $origin == MANUAL ]] && printf 'FAILED · manual' || printf FAILED)"
        ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
        delivery_failed=1
    fi
    KA_T_SECONDARY_REMAIN[$uuid]=${KA_T_SECONDARY_INTERVAL[$uuid]}
    ka_state_save_target "$uuid" || return
    # Match MAIN semantics: reset after an attempted event, while returning a
    # transport error so manual IPC callers are not told the send succeeded.
    ((delivery_failed == 0)) || return 5
}

# Role: Preserve all countdowns when a large scheduler gap indicates suspend or process stall.
ka_scheduler_preserve_gap() {
    local elapsed=$1 uuid
    for uuid in "${KA_T_UUIDS[@]}"; do
        [[ ${KA_T_STATUS[$uuid]} == UNAVAILABLE ]] && continue
        ka_log_event "$uuid" TIMER "scheduler gap ${elapsed}s; countdown preserved" PRESERVED
    done
}

# Role: Decrement ACTIVE target timers by elapsed seconds and fire due events in priority order.
ka_scheduler_tick() {
    local elapsed=$1 uuid
    ((elapsed > 0)) || return 0
    if ((elapsed > ${KEEPALIVE_SUSPEND_GAP:-2})); then
        ka_scheduler_preserve_gap "$elapsed"
        return 0
    fi

    for uuid in "${KA_T_UUIDS[@]}"; do
        [[ ${KA_T_STATUS[$uuid]} == ACTIVE ]] || continue
        KA_T_MAIN_REMAIN[$uuid]=$((KA_T_MAIN_REMAIN[$uuid] - elapsed))
        ((KA_T_MAIN_REMAIN[$uuid] < 0)) && KA_T_MAIN_REMAIN[$uuid]=0

        if [[ ${KA_T_SECONDARY_ENABLED[$uuid]} == 1 ]]; then
            KA_T_SECONDARY_REMAIN[$uuid]=$((KA_T_SECONDARY_REMAIN[$uuid] - elapsed))
            ((KA_T_SECONDARY_REMAIN[$uuid] < 0)) && KA_T_SECONDARY_REMAIN[$uuid]=0
        fi

        # Secondary intentionally preempts main when both timers become due together.
        if [[ ${KA_T_SECONDARY_ENABLED[$uuid]} == 1 ]] && ((KA_T_SECONDARY_REMAIN[$uuid] <= 0)); then
            ka_scheduler_send_secondary "$uuid" AUTO || true
        fi
        [[ ${KA_T_STATUS[$uuid]} == ACTIVE ]] || continue
        if ((KA_T_MAIN_REMAIN[$uuid] <= 0)); then
            ka_scheduler_send_main "$uuid" AUTO || true
        fi
        ka_state_save_target "$uuid"
    done
}
