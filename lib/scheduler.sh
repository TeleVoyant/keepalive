#!/usr/bin/env bash
# Multi-target countdown scheduler and delivery semantics.

# Role: Validate a target immediately before input injection, marking it unavailable on failure.
ka_scheduler_validate_before_send() {
    local uuid=$1 rc reason backend
    KA_SCHEDULER_VALIDATION_REASON=''
    [[ ${KA_T_STATUS[$uuid]-} != UNAVAILABLE ]] || { KA_SCHEDULER_VALIDATION_REASON=${KA_T_REASON[$uuid]:-'target is unavailable'}; return 1; }
    if ka_transport_validate_target "$uuid"; then
        KA_T_STRIKES[$uuid]=0
        return 0
    else
        rc=$?
    fi
    backend=${KA_T_BACKEND[$uuid]:-konsole}
    reason=$(ka_transport_validation_reason "$backend" "$rc")
    KA_SCHEDULER_VALIDATION_REASON=$reason
    if ka_transport_validation_is_transient "$backend" "$rc"; then
        return 2
    fi
    if ! ka_state_mark_unavailable "$uuid" "$reason"; then
        KA_SCHEDULER_VALIDATION_REASON=${KA_LAST_ERROR:-'could not save unavailable target state'}
        return 3
    fi
    return 1
}

# Role: Record one delivery result in the checkpoint fields and event log together.
# Callers checkpoint after this helper at the existing scheduler commit point; keeping the
# metadata update here avoids a second write per send and makes every delivery surface agree.
ka_scheduler_log_delivery() {
    local uuid=$1 event=$2 detail=${3-} result=${4-}
    case $event in
        MAIN|SECONDARY|ENTER)
            printf -v KA_T_LAST_DELIVERY_TIME["$uuid"] '%(%F %T)T' -1
            KA_T_LAST_DELIVERY_EVENT[$uuid]=$event
            KA_T_LAST_DELIVERY_RESULT[$uuid]=$result
            # The detail is the delivered text; it is display metadata, so it is kept short.
            KA_T_LAST_DELIVERY_DETAIL[$uuid]=${detail:0:${KA_LAST_DELIVERY_DETAIL_MAX:-256}}
            ;;
    esac
    ka_log_event "$uuid" "$event" "$detail" "$result"
}

# Role: Canonicalize one pending-submit owner, accepting the pre-owner in-memory flag.
ka_scheduler_pending_owner() {
    local uuid=$1
    local pending=${KA_T_PENDING_SUBMIT[$uuid]:-0}
    case $pending in
        0|MAIN|SECONDARY_AUTO|SECONDARY_MANUAL|STALE) REPLY=$pending ;;
        1) REPLY=MAIN ;;
        *) REPLY=STALE ;;
    esac
}

# Role: Name the pending-submit owner represented by one scheduler event.
ka_scheduler_event_owner() {
    local event=$1 origin=${2:-AUTO}
    if [[ $event == MAIN ]]; then
        REPLY=MAIN
    elif [[ $origin == AUTO ]]; then
        REPLY=SECONDARY_AUTO
    else
        REPLY=SECONDARY_MANUAL
    fi
}

# Role: Apply the exactly-once state transition after an owed Enter succeeds.
ka_scheduler_complete_pending_owner() {
    local uuid=$1 owner=$2 count=${3-} index
    case $owner in
        MAIN)
            if [[ -z $count ]]; then
                count=0
                count=$(ka_state_message_count "$uuid") || count=0
            fi
            if ((count > 0)); then
                index=${KA_T_MAIN_INDEX[$uuid]:-0}
                ((index >= 0 && index < count)) || index=0
                KA_T_MAIN_INDEX[$uuid]=$(((index + 1) % count))
            fi
            ;;
        SECONDARY_AUTO)
            KA_T_SECONDARY_DONE[$uuid]=1
            ;;
        SECONDARY_MANUAL|STALE)
            :
            ;;
        *)
            return 1
            ;;
    esac
}

# Role: Submit an owed line and record its owner's completion before any new event.
ka_scheduler_submit_pending() {
    local uuid=$1 owner=$2 count=${3-} submit_only=${4:-1} mode=${5:-${KA_T_MODE[$1]}} event detail result
    case $owner in
        MAIN) event=MAIN; detail='[SUBMIT] pending MAIN'; result=SENT ;;
        SECONDARY_AUTO) event=SECONDARY; detail='[SUBMIT] pending secondary'; result=SENT ;;
        SECONDARY_MANUAL) event=SECONDARY; detail='[SUBMIT] pending secondary'; result='SENT · manual' ;;
        STALE) event=CONFIG; detail='[SUBMIT] stale pending'; result=SENT ;;
        *) return 1 ;;
    esac
    # An ENTER_ONLY target delivers only Enter whichever timer owns it: record ENTER, as
    # ka_scheduler_send_main and ka_scheduler_send_secondary do.
    [[ $mode == ENTER_ONLY && ($event == MAIN || $event == SECONDARY) ]] && event=ENTER
    if ka_transport_deliver "$uuid" "$mode" '' "$submit_only"; then
        ka_scheduler_complete_pending_owner "$uuid" "$owner" "$count" || return 1
        KA_T_PENDING_SUBMIT[$uuid]=0
        ka_scheduler_log_delivery "$uuid" "$event" "$detail" "$result"
        ka_notify_sent "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
        return 0
    else
        local delivery_rc=$?
    fi
    if ((delivery_rc == 3)); then
        KA_LAST_ERROR='message delivered but submit failed; the pending owner remains owed'
    else
        ka_transport_failure_reason "$uuid" submit
        KA_LAST_ERROR=$REPLY
    fi
    return "$delivery_rc"
}

# Role: Persist scheduler mutations and retain a dirty retry marker if the write fails.
ka_scheduler_checkpoint() {
    local uuid=$1 rc
    if ka_state_save_target "$uuid"; then
        return 0
    else
        rc=$?
    fi
    ka_state_mark_dirty "$uuid"
    return "$rc"
}

# Role: Deliver one MAIN event using the selected target's current mode and message rotation.
ka_scheduler_send_main() {
    local uuid=$1 origin=${2:-AUTO}
    local count index message detail pending_owner pending_submit_only validation_rc
    local delivery_failed=0 delivery_rc failure delivery_event=MAIN
    ka_state_has_target "$uuid" || return 1
    # An ENTER_ONLY target's main timer delivers only Enter; record it as the ENTER event
    # the one-shot Enter uses, so the log and last-delivery fields say what was sent.
    [[ ${KA_T_MODE[$uuid]-} == ENTER_ONLY ]] && delivery_event=ENTER
    [[ ${KA_T_STATUS[$uuid]} == ACTIVE || $origin == MANUAL ]] || return 2
    if ka_scheduler_validate_before_send "$uuid"; then :; else
        validation_rc=$?
        detail=${KA_SCHEDULER_VALIDATION_REASON:-'Target validation failed'}
        KA_LAST_ERROR=$detail
        if ((validation_rc == 2)); then
            ka_scheduler_log_delivery "$uuid" "$delivery_event" "$detail" "$([[ $origin == MANUAL ]] && printf 'FAILED · manual' || printf FAILED)"
            ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
            KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
            ka_scheduler_checkpoint "$uuid" || return
        fi
        return 3
    fi

    if count=$(ka_state_message_count "$uuid"); then :; else
        # A vanished or unreadable rotation is a configuration fault, not evidence that
        # the terminal is gone. Consume the event so it does not retry every tick.
        KA_LAST_ERROR='main message rotation could not be read; reconfigure it'
        KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
        ka_scheduler_checkpoint "$uuid" || return
        ka_log_event "$uuid" CONFIG "$KA_LAST_ERROR" FAILED
        return 4
    fi
    if ((count == 0)); then
        # A missing rotation is a configuration fault, not evidence that the Konsole
        # session is gone. Marking the target UNAVAILABLE made it unrecoverable, because
        # an unavailable record cannot be reconfigured - only deleted and rebuilt. Consume
        # the event so this does not retry every tick, and leave the target usable.
        KA_LAST_ERROR='no main messages are stored for this target; reconfigure it'
        KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
        ka_scheduler_checkpoint "$uuid" || return
        ka_log_event "$uuid" CONFIG "$KA_LAST_ERROR" FAILED
        return 4
    fi
    index=${KA_T_MAIN_INDEX[$uuid]}
    ((index >= 0 && index < count)) || index=0
    if message=$(ka_state_message_at "$uuid" "$index"); then :; else
        # The count/read pair can race with a configuration cleanup. Never turn that
        # failed read into an empty terminal input; consume it as an actionable CONFIG fault.
        KA_LAST_ERROR="main message $((index + 1)) could not be read; reconfigure it"
        KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
        ka_scheduler_checkpoint "$uuid" || return
        ka_log_event "$uuid" CONFIG "$KA_LAST_ERROR" FAILED
        return 4
    fi

    ka_scheduler_pending_owner "$uuid"
    pending_owner=$REPLY
    # Normalize legacy in-memory 1 before the first checkpoint after this event.
    KA_T_PENDING_SUBMIT[$uuid]=$pending_owner

    # Consume this timer event before delivering. The reset used to happen afterwards, so
    # a crash between the send and the checkpoint left the countdown at zero and the
    # restarted daemon delivered the same event again. Resetting first matches the
    # existing policy that a failed attempt still consumes its event.
    KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
    ka_scheduler_checkpoint "$uuid" || return

    if [[ $pending_owner != 0 ]]; then
        if [[ ${KA_T_MODE[$uuid]} == ENTER_ONLY || $pending_owner == MAIN ]]; then
            # In ENTER_ONLY mode this Enter completes the owed owner instead of being
            # treated as an unrelated event. In MESSAGE_ENTER, a MAIN owner is the same
            # event and therefore must not append its message a second time.
            pending_submit_only=1
            [[ ${KA_T_MODE[$uuid]} == ENTER_ONLY ]] && pending_submit_only=0
            if ka_scheduler_submit_pending "$uuid" "$pending_owner" "$count" \
                "$pending_submit_only" "${KA_T_MODE[$uuid]}"; then
                ka_scheduler_checkpoint "$uuid" || return
                return 0
            else
                delivery_rc=$?
                detail='[ENTER]'
                [[ ${KA_T_MODE[$uuid]} == MESSAGE_ENTER ]] && detail="[SUBMIT] $message"
                failure='FAILED · submit owed'
                [[ $origin == MANUAL ]] && failure="$failure · manual"
                ka_scheduler_log_delivery "$uuid" "$delivery_event" "$detail" "$failure"
                ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
                ka_scheduler_checkpoint "$uuid" || return
                return 5
            fi
        fi

        # A different owner must be completed before this MAIN event can append its
        # message. If that Enter fails, consume this event but leave the owner pending.
        if ka_scheduler_submit_pending "$uuid" "$pending_owner" '' 1 MESSAGE_ENTER; then
            ka_scheduler_checkpoint "$uuid" || return
        else
            delivery_rc=$?
            detail=$message
            failure='FAILED · submit owed'
            [[ $origin == MANUAL ]] && failure="$failure · manual"
            ka_scheduler_log_delivery "$uuid" "$delivery_event" "$detail" "$failure"
            ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
            ka_scheduler_checkpoint "$uuid" || return
            return 5
        fi
    fi

    if [[ ${KA_T_MODE[$uuid]} == ENTER_ONLY ]]; then detail='[ENTER]'; else detail=$message; fi
    if ka_transport_deliver "$uuid" "${KA_T_MODE[$uuid]}" "$message" 0; then
        KA_T_PENDING_SUBMIT[$uuid]=0
        ka_scheduler_log_delivery "$uuid" "$delivery_event" "$detail" "$([[ $origin == MANUAL ]] && printf 'SENT · manual' || printf SENT)"
        ka_notify_sent "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
        # ENTER_ONLY intentionally does not consume a queued message because no message was sent.
        if [[ ${KA_T_MODE[$uuid]} == MESSAGE_ENTER ]]; then
            KA_T_MAIN_INDEX[$uuid]=$(((index + 1) % count))
        fi
    else
        delivery_rc=$?
        failure=FAILED
        if ((delivery_rc == 3)); then
            # The text is already on the target's input line; only the submit is owed.
            KA_T_PENDING_SUBMIT[$uuid]=MAIN
            KA_LAST_ERROR='message delivered but submit failed; the next attempt will only submit'
            failure='FAILED · submit owed'
        else
            ka_transport_failure_reason "$uuid" main
            KA_LAST_ERROR=$REPLY
        fi
        [[ $origin == MANUAL ]] && failure="$failure · manual"
        ka_scheduler_log_delivery "$uuid" "$delivery_event" "$detail" "$failure"
        ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
        delivery_failed=1
    fi
    # Second checkpoint: persist the rotation advance or the pending-submit owner.
    ka_scheduler_checkpoint "$uuid" || return
    # A failed transport attempt still consumes this timer event, but callers must
    # receive failure rather than an incorrect IPC success response.
    ((delivery_failed == 0)) || return 5
}

# Role: Deliver one SECONDARY event while preserving the main countdown exactly.
ka_scheduler_send_secondary() {
    local uuid=$1 origin=${2:-AUTO}
    local message detail pending_owner current_owner pending_submit_only validation_rc
    local delivery_failed=0 delivery_rc failure delivery_event=SECONDARY
    ka_state_has_target "$uuid" || return 1
    [[ ${KA_T_MODE[$uuid]-} == ENTER_ONLY ]] && delivery_event=ENTER
    [[ ${KA_T_SECONDARY_ENABLED[$uuid]} == 1 ]] || return 2
    [[ ${KA_T_STATUS[$uuid]} == ACTIVE || $origin == MANUAL ]] || return 3
    if ka_scheduler_validate_before_send "$uuid"; then :; else
        validation_rc=$?
        detail=${KA_SCHEDULER_VALIDATION_REASON:-'Target validation failed'}
        KA_LAST_ERROR=$detail
        if ((validation_rc == 2)); then
            ka_scheduler_log_delivery "$uuid" "$delivery_event" "$detail" "$([[ $origin == MANUAL ]] && printf 'FAILED · manual' || printf FAILED)"
            ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
            KA_T_SECONDARY_REMAIN[$uuid]=${KA_T_SECONDARY_INTERVAL[$uuid]}
            ka_scheduler_checkpoint "$uuid" || return
        fi
        return 4
    fi

    message=${KA_T_SECONDARY_MESSAGE[$uuid]}
    if [[ ${KA_T_MODE[$uuid]} == ENTER_ONLY ]]; then detail='[ENTER]'; else detail=$message; fi
    ka_scheduler_event_owner SECONDARY "$origin"
    current_owner=$REPLY
    ka_scheduler_pending_owner "$uuid"
    pending_owner=$REPLY
    # Normalize legacy in-memory 1 before the first checkpoint after this event.
    KA_T_PENDING_SUBMIT[$uuid]=$pending_owner

    # Consume this timer event before delivering, for the same crash-window reason as MAIN.
    KA_T_SECONDARY_REMAIN[$uuid]=${KA_T_SECONDARY_INTERVAL[$uuid]}
    ka_scheduler_checkpoint "$uuid" || return

    if [[ $pending_owner != 0 ]]; then
        # Any secondary owner is the same kind as this event: the line already holds the
        # secondary message, whichever origin typed it. Submitting it and then typing it
        # again would hand the agent the same nudge twice in a row.
        if [[ ${KA_T_MODE[$uuid]} == ENTER_ONLY || $pending_owner == SECONDARY_* ]]; then
            # In ENTER_ONLY mode this Enter completes the owed owner; in MESSAGE_ENTER a
            # same-kind owner is the event itself and must not resend its text.
            pending_submit_only=1
            [[ ${KA_T_MODE[$uuid]} == ENTER_ONLY ]] && pending_submit_only=0
            if ka_scheduler_submit_pending "$uuid" "$pending_owner" '' \
                "$pending_submit_only" "${KA_T_MODE[$uuid]}"; then
                # An automatic event consumes the one-shot even when the line it completed
                # was typed by an earlier manual send.
                if [[ $current_owner == SECONDARY_AUTO && $pending_owner == SECONDARY_* ]]; then
                    KA_T_SECONDARY_DONE[$uuid]=1
                fi
                ka_scheduler_checkpoint "$uuid" || return
                return 0
            else
                delivery_rc=$?
                failure='FAILED · submit owed'
                [[ $origin == MANUAL ]] && failure="$failure · manual"
                ka_scheduler_log_delivery "$uuid" "$delivery_event" "$detail" "$failure"
                ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
                ka_scheduler_checkpoint "$uuid" || return
                return 5
            fi
        fi

        # A different owner must be completed before this SECONDARY event can append its
        # message. If that Enter fails, consume this event but leave the owner pending.
        if ka_scheduler_submit_pending "$uuid" "$pending_owner" '' 1 MESSAGE_ENTER; then
            ka_scheduler_checkpoint "$uuid" || return
        else
            delivery_rc=$?
            failure='FAILED · submit owed'
            [[ $origin == MANUAL ]] && failure="$failure · manual"
            ka_scheduler_log_delivery "$uuid" "$delivery_event" "$detail" "$failure"
            ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
            ka_scheduler_checkpoint "$uuid" || return
            return 5
        fi
    fi

    if ka_transport_deliver "$uuid" "${KA_T_MODE[$uuid]}" "$message" 0; then
        KA_T_PENDING_SUBMIT[$uuid]=0
        # Only an automatic delivery consumes the one-shot; a manual send is on demand.
        [[ $origin == MANUAL ]] || KA_T_SECONDARY_DONE[$uuid]=1
        ka_scheduler_log_delivery "$uuid" "$delivery_event" "$detail" "$([[ $origin == MANUAL ]] && printf 'SENT · manual' || printf SENT)"
        ka_notify_sent "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
    else
        delivery_rc=$?
        failure=FAILED
        if ((delivery_rc == 3)); then
            KA_T_PENDING_SUBMIT[$uuid]=$current_owner
            KA_LAST_ERROR='message delivered but submit failed; the next attempt will only submit'
            failure='FAILED · submit owed'
        else
            ka_transport_failure_reason "$uuid" secondary
            KA_LAST_ERROR=$REPLY
        fi
        [[ $origin == MANUAL ]] && failure="$failure · manual"
        ka_scheduler_log_delivery "$uuid" "$delivery_event" "$detail" "$failure"
        ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" "$detail"
        delivery_failed=1
    fi
    # Second checkpoint: persist the one-shot flag or the pending-submit owner.
    ka_scheduler_checkpoint "$uuid" || return
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
    local uuid=$1 origin=${2:-MANUAL} validation_rc pending_owner delivery_rc
    ka_state_has_target "$uuid" || { ka_error 'unknown keep-alive target'; return 1; }
    [[ ${KA_T_STATUS[$uuid]} != UNAVAILABLE ]] || { ka_error 'unavailable targets cannot be sent to'; return 2; }
    if ka_scheduler_validate_before_send "$uuid"; then :; else
        validation_rc=$?
        KA_LAST_ERROR=${KA_SCHEDULER_VALIDATION_REASON:-'target validation failed'}
        if ((validation_rc == 2)); then
            # No delivery checkpoint exists on a pre-send validation refusal; retain the
            # existing event-log behavior without adding a write to this fast-fail path.
            ka_scheduler_log_delivery "$uuid" ENTER "$KA_LAST_ERROR" 'FAILED · manual'
        fi
        return 3
    fi

    ka_scheduler_pending_owner "$uuid"
    pending_owner=$REPLY
    KA_T_PENDING_SUBMIT[$uuid]=$pending_owner
    if [[ $pending_owner != 0 ]]; then
        # The one-shot Enter is itself the owed submit. It must apply the owner's
        # completion transition before the target resumes normal MESSAGE+ENTER mode.
        if ka_scheduler_submit_pending "$uuid" "$pending_owner" '' 0 ENTER_ONLY; then
            :
        else
            delivery_rc=$?
            KA_LAST_ERROR=${KA_LAST_ERROR:-'pending submit failed'}
            ka_scheduler_log_delivery "$uuid" ENTER '[ENTER] one-shot' 'FAILED · manual'
            ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" '[ENTER]'
            KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
            if ! ka_scheduler_checkpoint "$uuid"; then
                KA_LAST_ERROR+='; the updated target state could not be saved'
                ka_scheduler_log_delivery "$uuid" ENTER '[ENTER] one-shot' 'FAILED · checkpoint'
                return 6
            fi
            return 5
        fi
    else
        if ka_transport_deliver "$uuid" ENTER_ONLY ''; then
            :
        else
            delivery_rc=$?
            ka_transport_failure_reason "$uuid" Enter
            KA_LAST_ERROR=$REPLY
            ka_scheduler_log_delivery "$uuid" ENTER '[ENTER] one-shot' 'FAILED · manual'
            ka_notify_send_failed "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" '[ENTER]'
            KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
            if ! ka_scheduler_checkpoint "$uuid"; then
                KA_LAST_ERROR+='; the updated target state could not be saved'
                ka_scheduler_log_delivery "$uuid" ENTER '[ENTER] one-shot' 'FAILED · checkpoint'
                return 6
            fi
            return 5
        fi
    fi

    KA_T_PENDING_SUBMIT[$uuid]=0
    KA_T_MAIN_REMAIN[$uuid]=${KA_T_MAIN_INTERVAL[$uuid]}
    # Resume normal delivery; a one-shot Enter is not a mode change.
    KA_T_MODE[$uuid]=MESSAGE_ENTER
    # Record before the existing checkpoint so the durable outcome is committed with the
    # timer/mode transition; a failed checkpoint is retained as the dirty retry state.
    ka_scheduler_log_delivery "$uuid" ENTER '[ENTER] one-shot' 'SENT · manual'
    ka_notify_sent "${KA_T_NOTIFY[$uuid]}" "${KA_T_NAME[$uuid]}" '[ENTER]'
    if ! ka_scheduler_checkpoint "$uuid"; then
        KA_LAST_ERROR='Enter was delivered, but the updated target state could not be saved'
        ka_scheduler_log_delivery "$uuid" ENTER '[ENTER] one-shot' 'FAILED · checkpoint'
        return 6
    fi
    return 0
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
    local elapsed=$1 uuid
    # Second statement deliberately: bash expands every assignment word in one `local`
    # before creating any of them, so computing this alongside `elapsed` would read an
    # outer `elapsed` instead - which happened to be the caller's, with the same value.
    local backwards=$((-elapsed))
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
    local suspend_gap
    ka_tunable KEEPALIVE_SUSPEND_GAP 2
    suspend_gap=$REPLY
    if ((elapsed > suspend_gap)); then
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
        # Deliveries checkpoint themselves; a bare countdown decrement only needs to be
        # flushed periodically.
        ka_state_mark_dirty "$uuid"
    done
}
