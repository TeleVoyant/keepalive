#!/usr/bin/env bash
# Persistent per-user Keep Alive daemon lifecycle and event loop.

# Role: Acquire the single-manager kernel lock so only one daemon owns runtime state.
ka_service_acquire_lock() {
    local lockfile="$KA_RUNTIME_DIR/manager.lock"
    exec {KA_MANAGER_LOCK_FD}>"$lockfile"
    flock -n "$KA_MANAGER_LOCK_FD" || return 1
}

# Role: Publish lightweight service metadata used by diagnostics and operator tooling.
ka_service_write_status() {
    local state=${1:-online}
    local payload
    printf -v payload 'state\t%s\npid\t%s\nversion\t%s\nupdated\t%s\n' \
        "$state" "$$" "${KEEPALIVE_VERSION:-unknown}" "$(ka_now_full)"
    ka_atomic_write_value "$KA_SERVICE_STATE_FILE" "$payload"
}

# Role: Mark daemon state stopped on normal/signalled exit while leaving socket activation intact.
ka_service_cleanup() {
    ka_service_write_status stopped 2>/dev/null || true
}

# Role: Validate restored runtime targets and record successful same-session daemon recovery.
ka_service_recover_targets() {
    local uuid old_status
    for uuid in "${KA_T_UUIDS[@]}"; do
        old_status=${KA_T_STATUS[$uuid]}
        [[ $old_status == UNAVAILABLE ]] && continue
        if ka_konsole_validate_target "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" "$uuid" \
            "${KA_T_TERM_PID[$uuid]}" "${KA_T_AI_PID[$uuid]}" "${KA_T_AI_START[$uuid]}"; then
            KA_T_LAST_SEEN[$uuid]=$(ka_now_full)
            ka_state_save_target "$uuid"
            ka_log_event "$uuid" SERVICE "daemon recovered; countdown preserved" "$old_status"
        else
            local rc=$? reason
            reason=$(ka_konsole_validation_reason "$rc")
            if ka_konsole_validation_is_transient "$rc"; then
                ka_log_event "$uuid" SERVICE "daemon recovery validation deferred: $reason" "$old_status"
            else
                ka_state_mark_unavailable "$uuid" "$reason"
            fi
        fi
    done
}

# Role: Run one periodic daemon task, degrading a failure into a warning.
#
# The loop runs under `set -e`, so an unguarded transient I/O failure - a full tmpfs, a
# permissions change, a runtime directory being replaced - aborts the daemon outright.
# `Restart=on-failure` then retries every RestartSec until StartLimitBurst trips and the
# unit stays dead. Periodic work must survive one bad cycle and try again on the next.
ka_service_try() {
    local label=$1 rc=0
    shift
    # Captured explicitly: an `if` whose condition fails and which has no else branch
    # evaluates to 0, so reading $? afterwards would always report success.
    "$@" || rc=$?
    ((rc == 0)) && return 0
    ka_warn "$label failed (status $rc); continuing"
    return 0
}

# Role: Report whether the runtime directory still exists.
# Its disappearance means the login session ended and there is nothing left to own, which
# is a clean stop rather than an error to retry.
ka_service_runtime_present() {
    [[ -d $KA_RUNTIME_DIR ]]
}

# Role: Choose the discovery cadence from whether any client is currently watching.
# Discovery exists to populate AVAILABLE rows for clients. With nobody attached and
# nothing monitored, polling the bus every few seconds is pure waste, and it is the
# daemon's single largest cost.
# Sets KA_DISCOVERY_INTERVAL and forks nothing: it is consulted from the loop, where a
# command substitution would cost more than the polling it is meant to avoid.
ka_service_discovery_interval() {
    local fast idle
    ka_tunable KEEPALIVE_DISCOVERY_INTERVAL 3;       fast=$REPLY
    ka_tunable KEEPALIVE_IDLE_DISCOVERY_INTERVAL 30; idle=$REPLY
    if ((${#KA_T_UUIDS[@]} != 0)); then
        KA_DISCOVERY_INTERVAL=$fast
        return 0
    fi
    local seen='' now
    [[ -r $KA_CLIENT_PRESENCE_FILE ]] && { read -r seen <"$KA_CLIENT_PRESENCE_FILE" || true; }
    [[ $seen =~ ^[0-9]+$ ]] || seen=0
    printf -v now '%(%s)T' -1
    ka_tunable KEEPALIVE_CLIENT_PRESENCE_TTL 20
    if ((now - seen <= REPLY)); then
        KA_DISCOVERY_INTERVAL=$fast
    else
        KA_DISCOVERY_INTERVAL=$idle
    fi
}

# Role: Run the single-threaded daemon loop that interleaves IPC, timers, health, and discovery.
ka_service_loop() {
    local control_read=0
    local now last_tick elapsed last_health last_discovery last_publish last_cleanup last_status
    local stale_logged=0 clock_warned=0 control_failures=0
    # Resolved once: these are process-wide settings, and validating them here keeps an
    # operator typo out of every arithmetic expression below.
    local health_interval status_interval cleanup_interval
    ka_tunable KEEPALIVE_HEALTH_INTERVAL 2;    health_interval=$REPLY
    ka_tunable KEEPALIVE_STATUS_INTERVAL 15;   status_interval=$REPLY
    ka_tunable KEEPALIVE_CLEANUP_INTERVAL 300; cleanup_interval=$REPLY
    ka_now_monotonic || { ka_error 'monotonic clock source is unavailable'; return 1; }
    last_tick=$REPLY
    last_health=$last_tick
    last_discovery=$last_tick
    last_publish=$last_tick
    last_cleanup=$last_tick
    last_status=$last_tick

    while true; do
        ka_ipc_service_read 0.20 && control_read=0 || control_read=$?
        case $control_read in
            0)
                control_failures=0
                [[ -n ${KA_IPC_LINE:-} ]] && ka_ipc_handle_line "$KA_IPC_LINE" || true
                ;;
            1)
                # Idle timeout: this is what paces the loop.
                control_failures=0
                ;;
            *)
                # Not a timeout, so the descriptor returned immediately and the loop has
                # lost its pacing. Reopen rather than spin, and give up if that keeps
                # failing so the service manager can restart a working instance.
                control_failures=$((control_failures + 1))
                ka_warn "control FIFO read failed ($control_failures); reopening"
                if ((control_failures > 5)) || ! ka_ipc_service_reopen; then
                    ka_error 'control FIFO is unusable; stopping so it can be recreated'
                    return 1
                fi
                continue
                ;;
        esac

        if ! ka_now_monotonic; then
            # Rate limited: paced only by the read above, this would otherwise write five
            # identical warnings a second for as long as the condition lasts.
            ((clock_warned == 1)) || ka_warn 'monotonic clock read failed; countdowns remain preserved'
            clock_warned=1
            continue
        fi
        clock_warned=0
        now=$REPLY
        if ! ka_service_runtime_present; then
            ka_info "runtime directory $KA_RUNTIME_DIR disappeared; the session has ended"
            return 0
        fi

        elapsed=$((now - last_tick))
        if ((elapsed < 0)); then
            ka_service_try 'timer tick' ka_scheduler_tick "$elapsed"
            ka_warn "monotonic clock moved backward $((-elapsed))s; scheduler anchors reset"
            last_tick=$now
            last_health=$now
            last_discovery=$now
            last_publish=$now
            last_cleanup=$now
            last_status=$now
            continue
        elif ((elapsed > 0)); then
            ka_service_try 'timer tick' ka_scheduler_tick "$elapsed"
            last_tick=$now
        fi

        if ((now - last_health >= health_interval)); then
            ka_service_try 'target validation' ka_state_validate_targets
            last_health=$now
        fi

        if ((now - last_discovery >= ${KA_DISCOVERY_INTERVAL:-3})); then
            # Not wrapped in ka_service_try: a non-zero return here means "the pass hit
            # its budget", which is a normal signal handled below, not a failure to warn about.
            if ka_state_refresh_discovery; then
                stale_logged=0
            elif ((stale_logged == 0)); then
                # The pass hit its budget, so the previous snapshot is retained. Warn once
                # per episode rather than on every cycle.
                ka_warn 'Konsole discovery exceeded its per-pass budget; using the previous snapshot'
                stale_logged=1
            fi
            last_discovery=$now
        fi

        if ((now - last_publish >= 1)); then
            ka_service_try 'index publication' ka_state_publish_index
            # Re-evaluated once a second, not once per iteration.
            ka_service_discovery_interval
            last_publish=$now
        fi

        # Diagnostics only; clients read the index, not this file.
        if ((now - last_status >= status_interval)); then
            ka_service_try 'service status write' ka_service_write_status online
            last_status=$now
        fi

        if ((now - last_cleanup >= cleanup_interval)); then
            ka_service_try 'stale request cleanup' ka_ipc_cleanup_stale
            last_cleanup=$now
        fi
    done
}

# Role: Initialize dependencies/state and enter persistent per-user service mode.
ka_service_main() {
    if ((EUID == 0)); then
        ka_error 'Keep Alive is a per-user service and must not run as root'
        return 1
    fi

    ka_xdg_init
    ka_ensure_runtime_dirs || { ka_error 'runtime directory is not usable'; return 1; }
    ka_ensure_config_dirs
    ka_profile_init_defaults
    ka_now_monotonic || { ka_error 'a valid monotonic clock source (/proc/uptime by default) is required'; return 1; }
    command -v timeout >/dev/null 2>&1 || { ka_error 'GNU timeout is required for bounded D-Bus calls'; return 1; }
    ka_qdbus_find || { ka_error 'no qdbus tool found (qdbus6/qdbus required)'; return 1; }
    ka_dbus_send_find || ka_warn 'dbus-send not found; falling back to the slower qdbus transport'
    ka_dbus_use_send && ka_info "read-only D-Bus transport: $KA_DBUS_SEND"
    ka_classifier_init
    ka_state_init_arrays
    # Another instance already owns the runtime state, so there is nothing for this one to
    # do. Exiting successfully keeps systemd from treating it as a failure and restarting
    # every RestartSec until the start limit trips.
    if ! ka_service_acquire_lock; then
        ka_info 'another Keep Alive service instance owns the runtime state; exiting quietly'
        return 0
    fi
    ka_ipc_service_open

    trap ka_service_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    ka_cleanup_staged_dirs "$KA_RUNTIME_DIR"
    # Sweep once at startup too; waiting a full interval leaves debris from the previous
    # daemon lifetime visible for no reason.
    ka_ipc_cleanup_stale
    ka_state_load_all_targets
    ka_state_refresh_discovery
    ka_service_recover_targets
    ka_state_publish_index
    ka_service_write_status online
    ka_service_loop
}
