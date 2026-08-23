#!/usr/bin/env bash
# Multi-target countdown scheduler and delivery semantics.

# Role: Validate a target immediately before input injection, marking it unavailable on failure.
ka_scheduler_validate_before_send() {
    local uuid=$1 rc reason
    KA_SCHEDULER_VALIDATION_REASON=''
    [[ ${KA_T_STATUS[$uuid]-} != UNAVAILABLE ]] || return 1
    if ka_konsole_validate_target "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" "$uuid" \
        "${KA_T_TERM_PID[$uuid]}" "${KA_T_AI_PID[$uuid]}" "${KA_T_AI_START[$uuid]}"; then
        return 0
    else
        rc=$?
    fi
    reason=$(ka_konsole_validation_reason "$rc")
    KA_SCHEDULER_VALIDATION_REASON=$reason
    if ka_konsole_validation_is_transient "$rc"; then
        return 2
    fi
    ka_state_mark_unavailable "$uuid" "$reason"
    return 1
}

# Role: Deliver one MAIN event using the selected target's current mode and message rotation.
ka_scheduler_send_main() {
    local uuid=$1 origin=${2:-AUTO} count index message detail delivery_failed=0 validation_rc
    ka_state_has_target "$uuid" || return 1
    [[ ${KA_T_STATUS[$uuid]} == ACTIVE || $origin == MANUAL ]] || return 2
    if ka_scheduler_validate_before_send "$uuid"; then :; else
        validation_rc=$?
        if ((validation_rc == 2)); then
            detail=${KA_SCHEDULER_VALIDATION_REASON:-'Transient target validation failure'}
            KA_LAST_ERROR=$detail
            ka_log_event "$uuid" MAIN "$detail" "$([[ $origin == MANUAL ]] && printf 'FAILED · manual' || printf FAILED)"
            ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
            KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
            ka_state_save_target "$uuid" || return
        fi
        return 3
    fi

    count=$(ka_state_message_count "$uuid")
    ((count > 0)) || { ka_state_mark_unavailable "$uuid" 'No main messages remain in target state'; return 4; }
    index=${KA_T_MAIN_INDEX[$uuid]}
    ((index >= 0 && index < count)) || index=0
    message=$(ka_state_message_at "$uuid" "$index")

    # Consume this timer event before delivering. The reset used to happen afterwards, so
    # a crash between the send and the checkpoint left the countdown at zero and the
    # restarted daemon delivered the same event again. Resetting first matches the
    # existing policy that a failed attempt still consumes its event.
    KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
    ka_state_save_target "$uuid" || return

    local submit_only=${KA_T_PENDING_SUBMIT[$uuid]:-0}
    if [[ ${KA_T_MODE[$uuid]} == ENTER_ONLY ]]; then
        detail='[ENTER]'
        submit_only=0
    elif ((submit_only == 1)); then
        detail="[SUBMIT] $message"
    else
        detail=$message
    fi

    if ka_konsole_deliver "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" "${KA_T_MODE[$uuid]}" "$message" "$submit_only"; then
        KA_T_PENDING_SUBMIT[$uuid]=0
        ka_log_event "$uuid" MAIN "$detail" "$([[ $origin == MANUAL ]] && printf 'SENT · manual' || printf SENT)"
        ka_notify_sent "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
        # ENTER_ONLY intentionally does not consume a queued message because no message was sent.
        if [[ ${KA_T_MODE[$uuid]} == MESSAGE_ENTER ]]; then
            KA_T_MAIN_INDEX[$uuid]=$(((index + 1) % count))
        fi
    else
        local deliver_rc=$? failure=FAILED
        if ((deliver_rc == 3)); then
            # The text is already on the target's input line; only the submit is owed.
            KA_T_PENDING_SUBMIT[$uuid]=1
            KA_LAST_ERROR='message delivered but submit failed; the next attempt will only submit'
            failure='FAILED · submit owed'
        else
            KA_LAST_ERROR='Konsole rejected the main send (transport failure)'
        fi
        [[ $origin == MANUAL ]] && failure="$failure · manual"
        ka_log_event "$uuid" MAIN "$detail" "$failure"
        ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
        delivery_failed=1
    fi
    # Second checkpoint: persist the rotation advance or the pending-submit state.
    ka_state_save_target "$uuid" || return
    # A failed transport attempt still consumes this timer event, but callers must
    # receive failure rather than an incorrect IPC success response.
    ((delivery_failed == 0)) || return 5
}

# Role: Deliver one SECONDARY event while preserving the main countdown exactly.
ka_scheduler_send_secondary() {
    local uuid=$1 origin=${2:-AUTO} message detail delivery_failed=0 validation_rc
    ka_state_has_target "$uuid" || return 1
    [[ ${KA_T_SECONDARY_ENABLED[$uuid]} == 1 ]] || return 2
    [[ ${KA_T_STATUS[$uuid]} == ACTIVE || $origin == MANUAL ]] || return 3
    if ka_scheduler_validate_before_send "$uuid"; then :; else
        validation_rc=$?
        if ((validation_rc == 2)); then
            detail=${KA_SCHEDULER_VALIDATION_REASON:-'Transient target validation failure'}
            KA_LAST_ERROR=$detail
            ka_log_event "$uuid" SECONDARY "$detail" "$([[ $origin == MANUAL ]] && printf 'FAILED · manual' || printf FAILED)"
            ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
            KA_T_SECONDARY_REMAIN[$uuid]=${KA_T_SECONDARY_INTERVAL[$uuid]}
            ka_state_save_target "$uuid" || return
        fi
        return 4
    fi

    # Consume this timer event before delivering, for the same crash-window reason as MAIN.
    KA_T_SECONDARY_REMAIN[$uuid]=${KA_T_SECONDARY_INTERVAL[$uuid]}
    ka_state_save_target "$uuid" || return

    message=${KA_T_SECONDARY_MESSAGE[$uuid]}
    if [[ ${KA_T_MODE[$uuid]} == ENTER_ONLY ]]; then detail='[ENTER]'; else detail=$message; fi

    if ka_konsole_deliver "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" "${KA_T_MODE[$uuid]}" "$message" "${KA_T_PENDING_SUBMIT[$uuid]:-0}"; then
        KA_T_PENDING_SUBMIT[$uuid]=0
        # Only an automatic delivery consumes the one-shot; a manual send is on demand.
        [[ $origin == MANUAL ]] || KA_T_SECONDARY_DONE[$uuid]=1
        ka_log_event "$uuid" SECONDARY "$detail" "$([[ $origin == MANUAL ]] && printf 'SENT · manual' || printf SENT)"
        ka_notify_sent "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
    else
        local deliver_rc=$? failure=FAILED
        if ((deliver_rc == 3)); then
            KA_T_PENDING_SUBMIT[$uuid]=1
            KA_LAST_ERROR='message delivered but submit failed; the next attempt will only submit'
            failure='FAILED · submit owed'
        else
            KA_LAST_ERROR='Konsole rejected the secondary send (transport failure)'
        fi
        [[ $origin == MANUAL ]] && failure="$failure · manual"
        ka_log_event "$uuid" SECONDARY "$detail" "$failure"
        ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
        delivery_failed=1
    fi
    # Second checkpoint: persist the one-shot flag or the pending-submit state.
    ka_state_save_target "$uuid" || return
    # Match MAIN semantics: the event is consumed even on failure, while callers still
    # receive a transport error rather than a false success.
    ((delivery_failed == 0)) || return 5
}

# Role: Send a single Enter now and return the target to MESSAGE+ENTER delivery.
#
# This is the detail view's `e`: press Enter once, then resume normal message delivery.
# It never consumes a queued message, and it completes a pending submit if one is owed,
# because a bare Enter is exactly what that state is waiting for.
ka_scheduler_send_enter_once() {
    local uuid=$1 origin=${2:-MANUAL} validation_rc
    ka_state_has_target "$uuid" || { ka_error 'unknown keep-alive target'; return 1; }
    [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || { ka_error 'unavailable targets cannot be sent to'; return 2; }
    if ka_scheduler_validate_before_send "$uuid"; then :; else
        validation_rc=$?
        KA_LAST_ERROR=${KA_SCHEDULER_VALIDATION_REASON:-'target validation failed'}
        if ((validation_rc == 2)); then
            ka_log_event "$uuid" MAIN "$KA_LAST_ERROR" 'FAILED · manual'
        fi
        return 3
    fi

    if ka_konsole_deliver "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" ENTER_ONLY ''; then
        KA_T_PENDING_SUBMIT[$uuid]=0
        ka_log_event "$uuid" MAIN '[ENTER] one-shot' 'SENT · manual'
        ka_notify_sent "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" '[ENTER]'
        KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
        # Resume normal delivery; a one-shot Enter is not a mode change.
        KA_T_MODE[$uuid]=MESSAGE_ENTER
        ka_state_save_target "$uuid"
        return 0
    fi

    KA_LAST_ERROR='Konsole rejected the Enter send (transport failure)'
    ka_log_event "$uuid" MAIN '[ENTER] one-shot' 'FAILED · manual'
    ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" '[ENTER]'
    KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
    ka_state_save_target "$uuid"
    return 5
}

# Role: Preserve all countdowns when a large scheduler gap indicates suspend or process stall.
ka_scheduler_preserve_gap() {
    local elapsed=$1 uuid
    # One entry per contiguous gap episode. A stalled loop or a degraded bus would
    # otherwise append a line per target on every iteration, for as long as it lasts.
    ((${KA_SCHEDULER_GAP_ACTIVE:-0} == 0)) || return 0
    KA_SCHEDULER_GAP_ACTIVE=1
    for uuid in "${KA_T_UUIDS[@]}"; do
        [[ ${KA_T_STATUS[$uuid]} == UNAVAILABLE ]] && continue
        ka_log_event "$uuid" TIMER "scheduler gap ${elapsed}s; countdown preserved" PRESERVED
    done
}

# Role: Preserve target countdowns explicitly when the monotonic source moves backward.
ka_scheduler_preserve_clock_reset() {
    local elapsed=$1 uuid backwards=$((-elapsed))
    for uuid in "${KA_T_UUIDS[@]}"; do
        [[ ${KA_T_STATUS[$uuid]} == UNAVAILABLE ]] && continue
        ka_log_event "$uuid" TIMER "monotonic clock moved backward ${backwards}s; countdown preserved" PRESERVED
    done
}

# Role: Decrement ACTIVE target timers by elapsed seconds and fire due events in priority order.
ka_scheduler_tick() {
    local elapsed=$1 uuid
    if ((elapsed < 0)); then
        ka_scheduler_preserve_clock_reset "$elapsed"
        return 0
    fi
    ((elapsed > 0)) || return 0
    if ((elapsed > ${KEEPALIVE_SUSPEND_GAP:-2})); then
        ka_scheduler_preserve_gap "$elapsed"
        return 0
    fi

    # A tick inside the budget ends any gap episode.
    KA_SCHEDULER_GAP_ACTIVE=0
    for uuid in "${KA_T_UUIDS[@]}"; do
        [[ ${KA_T_STATUS[$uuid]} == ACTIVE ]] || continue
        KA_T_MAIN_REMAIN[$uuid]=$((KA_T_MAIN_REMAIN[$uuid] - elapsed))
        ((KA_T_MAIN_REMAIN[$uuid] < 0)) && KA_T_MAIN_REMAIN[$uuid]=0

        if [[ ${KA_T_SECONDARY_ENABLED[$uuid]} == 1 ]]; then
            KA_T_SECONDARY_REMAIN[$uuid]=$((KA_T_SECONDARY_REMAIN[$uuid] - elapsed))
            ((KA_T_SECONDARY_REMAIN[$uuid] < 0)) && KA_T_SECONDARY_REMAIN[$uuid]=0
        fi

        # Secondary intentionally preempts main when both timers become due together.
        # It is a one-shot nudge: after it has fired for this arming it stays quiet until
        # the target is reconfigured, rather than repeating every interval.
        if [[ ${KA_T_SECONDARY_ENABLED[$uuid]} == 1 ]] && ((KA_T_SECONDARY_REMAIN[$uuid] <= 0)) \
            && ((${KA_T_SECONDARY_DONE[$uuid]:-0} == 0)); then
            ka_scheduler_send_secondary "$uuid" AUTO || true
        fi
        [[ ${KA_T_STATUS[$uuid]} == ACTIVE ]] || continue
        if ((KA_T_MAIN_REMAIN[$uuid] <= 0)); then
            ka_scheduler_send_main "$uuid" AUTO || true
        fi
        ka_state_save_target "$uuid"
    done
}
