#!/usr/bin/env bash
# Persistent per-user Keep Alive daemon lifecycle and event loop.

# Role: Acquire the single-manager kernel lock so only one daemon owns runtime state.
ka_service_acquire_lock() {
    local lockfile="$KA_RUNTIME_DIR/manager.lock"
    exec {KA_MANAGER_LOCK_FD}>"$lockfile"
    flock -n "$KA_MANAGER_LOCK_FD" || {
        ka_error 'another Keep Alive service instance is already running'
        return 1
    }
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

# Role: Choose the discovery cadence from whether any client is currently watching.
# Discovery exists to populate AVAILABLE rows for clients. With nobody attached and
# nothing monitored, polling the bus every few seconds is pure waste, and it is the
# daemon's single largest cost.
# Sets KA_DISCOVERY_INTERVAL and forks nothing: it is consulted from the loop, where a
# command substitution would cost more than the polling it is meant to avoid.
ka_service_discovery_interval() {
    local fast=${KEEPALIVE_DISCOVERY_INTERVAL:-3} idle=${KEEPALIVE_IDLE_DISCOVERY_INTERVAL:-30}
    ka_is_positive_int "$fast" || fast=3
    ka_is_positive_int "$idle" || idle=30
    if ((${#KA_T_UUIDS[@]} != 0)); then
        KA_DISCOVERY_INTERVAL=$fast
        return 0
    fi
    local seen='' now
    [[ -r $KA_CLIENT_PRESENCE_FILE ]] && { read -r seen <"$KA_CLIENT_PRESENCE_FILE" || true; }
    [[ $seen =~ ^[0-9]+$ ]] || seen=0
    printf -v now '%(%s)T' -1
    if ((now - seen <= ${KEEPALIVE_CLIENT_PRESENCE_TTL:-20})); then
        KA_DISCOVERY_INTERVAL=$fast
    else
        KA_DISCOVERY_INTERVAL=$idle
    fi
}

# Role: Run the single-threaded daemon loop that interleaves IPC, timers, health, and discovery.
ka_service_loop() {
    local now last_tick elapsed last_health last_discovery last_publish last_cleanup last_status
    local stale_logged=0
    ka_now_monotonic || { ka_error 'monotonic clock source is unavailable'; return 1; }
    last_tick=$REPLY
    last_health=$last_tick
    last_discovery=$last_tick
    last_publish=$last_tick
    last_cleanup=$last_tick
    last_status=$last_tick

    while true; do
        if ka_ipc_service_read 0.20; then
            [[ -n ${KA_IPC_LINE:-} ]] && ka_ipc_handle_line "$KA_IPC_LINE" || true
        fi

        if ! ka_now_monotonic; then
            ka_warn 'monotonic clock read failed; countdowns remain preserved'
            continue
        fi
        now=$REPLY
        elapsed=$((now - last_tick))
        if ((elapsed < 0)); then
            ka_scheduler_tick "$elapsed"
            ka_warn "monotonic clock moved backward $((-elapsed))s; scheduler anchors reset"
            last_tick=$now
            last_health=$now
            last_discovery=$now
            last_publish=$now
            last_cleanup=$now
            last_status=$now
            continue
        elif ((elapsed > 0)); then
            ka_scheduler_tick "$elapsed"
            last_tick=$now
        fi

        if ((now - last_health >= ${KEEPALIVE_HEALTH_INTERVAL:-2})); then
            ka_state_validate_targets
            last_health=$now
        fi

        if ((now - last_discovery >= ${KA_DISCOVERY_INTERVAL:-3})); then
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
            ka_state_publish_index
            # Re-evaluated once a second, not once per iteration.
            ka_service_discovery_interval
            last_publish=$now
        fi

        # Diagnostics only; clients read the index, not this file.
        if ((now - last_status >= ${KEEPALIVE_STATUS_INTERVAL:-15})); then
            ka_service_write_status online
            last_status=$now
        fi

        if ((now - last_cleanup >= 3600)); then
            ka_ipc_cleanup_stale
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
    ka_service_acquire_lock || return
    ka_ipc_service_open

    trap ka_service_cleanup EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP

    ka_cleanup_staged_dirs "$KA_RUNTIME_DIR"
    ka_state_load_all_targets
    ka_state_refresh_discovery
    ka_service_recover_targets
    ka_state_publish_index
    ka_service_write_status online
    ka_service_loop
}
