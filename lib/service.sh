#!/usr/bin/env bash
# Persistent per-user Keep Alive daemon lifecycle and event loop.

# Role: Validate an existing manager lock as an owned real file at its canonical path.
ka_service_lockfile_is_safe() {
    local lockfile=$1 canonical
    [[ -f $lockfile && ! -L $lockfile && -O $lockfile ]] || return 1
    canonical=$(readlink -f -- "$lockfile") || return 1
    [[ $canonical == "$lockfile" ]]
}

# Role: Acquire the single-manager kernel lock without truncating or following a symlink.
ka_service_acquire_lock() {
    local lockfile="$KA_RUNTIME_DIR/manager.lock" fd_path resolved rc=0 had_noclobber=0
    if [[ -L $lockfile || (-e $lockfile && ! -f $lockfile) ]]; then
        ka_error "refusing unsafe manager lock: $lockfile"
        return 2
    fi
    if [[ -e $lockfile ]]; then
        ka_service_lockfile_is_safe "$lockfile" \
            || { ka_error "refusing unsafe manager lock: $lockfile"; return 2; }
        if ! exec {KA_MANAGER_LOCK_FD}>>"$lockfile"; then
            ka_error "could not open manager lock: $lockfile"
            return 2
        fi
    else
        [[ $- == *C* ]] && had_noclobber=1
        set -o noclobber
        if { exec {KA_MANAGER_LOCK_FD}>"$lockfile"; } 2>/dev/null; then
            :
        else
            rc=$?
            ((had_noclobber == 1)) || set +o noclobber
            # A concurrent daemon may have won the create. Re-open only after validating
            # the resulting path, and never use a truncating descriptor for that retry.
            if ! ka_service_lockfile_is_safe "$lockfile" \
                || ! exec {KA_MANAGER_LOCK_FD}>>"$lockfile"; then
                ka_error "could not safely create manager lock: $lockfile (status $rc)"
                return 2
            fi
        fi
        ((had_noclobber == 1)) || set +o noclobber
    fi
    fd_path="/proc/$$/fd/$KA_MANAGER_LOCK_FD"
    rc=0
    resolved=$(readlink -f -- "$fd_path") || rc=$?
    if ((rc != 0)) || [[ $resolved != "$lockfile" || ! -f $fd_path || ! -O $fd_path ]] \
        || ! chmod 600 "$fd_path" 2>/dev/null; then
        { exec {KA_MANAGER_LOCK_FD}>&-; } 2>/dev/null || true
        KA_MANAGER_LOCK_FD=''
        ka_error "manager lock descriptor does not resolve to the private lock file: $lockfile"
        return 2
    fi
    rc=0
    flock -n "$KA_MANAGER_LOCK_FD" || rc=$?
    ((rc == 0)) && return 0
    { exec {KA_MANAGER_LOCK_FD}>&-; } 2>/dev/null || true
    KA_MANAGER_LOCK_FD=''
    ((rc == 1)) && return 1
    ka_error "could not acquire manager lock: $lockfile (status $rc)"
    return 2
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
    # Flush first: countdowns advanced since the last periodic flush would otherwise be
    # lost, and a clean stop is exactly when they are worth keeping.
    ka_state_flush_dirty 2>/dev/null || true
    ka_service_write_status stopped 2>/dev/null || true
}

# Role: Stop at once while idle in the control read; otherwise record the stop for later.
#
# Exiting straight from the trap mid-work could land between a message and its Enter - an
# update's restart then duplicated the text afterwards, because the half-delivered state
# is not a checkpoint field - or after a timer event was consumed but before it was
# delivered. So a stop that arrives during work is only recorded and honoured at the top
# of the next iteration. One that arrives in the idle read exits immediately: Bash runs the
# trap at once but then resumes the read for its whole timeout, which is now up to seconds.
# The first signal's status is kept so the exit code still names it. KillMode=mixed in the
# unit keeps systemd from killing the in-flight helper processes themselves.
ka_service_request_stop() {
    [[ -n ${KA_SERVICE_STOP:-} ]] || KA_SERVICE_STOP=$1
    ((${KA_SERVICE_WAITING:-0} == 1)) && exit "$KA_SERVICE_STOP"
    return 0
}

# Role: Exit with the recorded signal status once a stop has been requested.
ka_service_honour_stop() {
    [[ -n ${KA_SERVICE_STOP:-} ]] || return 0
    ka_info "stop requested; exiting between deliveries"
    exit "$KA_SERVICE_STOP"
}

# Role: Validate restored runtime targets and record successful same-session daemon recovery.
ka_service_recover_targets() {
    local uuid old_status backend failed=0
    for uuid in "${KA_T_UUIDS[@]}"; do
        old_status=${KA_T_STATUS[$uuid]}
        [[ $old_status == UNAVAILABLE ]] && continue
        if ka_transport_validate_target "$uuid"; then
            KA_T_LAST_SEEN[$uuid]=$(ka_now_full)
            if ka_state_save_target "$uuid"; then
                ka_log_event "$uuid" SERVICE "daemon recovered; countdown preserved" "$old_status"
            else
                ka_state_mark_dirty "$uuid"
                ka_warn "could not checkpoint recovered target $uuid"
                failed=1
            fi
        else
            local rc=$? reason
            backend=${KA_T_BACKEND[$uuid]:-konsole}
            reason=$(ka_transport_validation_reason "$backend" "$rc")
            if ka_transport_validation_is_transient "$backend" "$rc"; then
                ka_log_event "$uuid" SERVICE "daemon recovery validation deferred: $reason" "$old_status"
            else
                ka_state_mark_unavailable "$uuid" "$reason" || failed=1
            fi
        fi
    done
    return "$failed"
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

# Role: Normalize one backend enable switch to auto, 0, or 1.
ka_service_backend_setting() {
    local name=$1 value
    value=${!name:-auto}
    case $value in
        auto|0|1) REPLY=$value ;;
        *)
            ka_warn "$name=$value is invalid; using auto"
            REPLY=auto
            ;;
    esac
}

# Role: Choose discovery and index cadence from whether any client is currently watching.
# Discovery exists to populate AVAILABLE rows for clients, and the index exists to be read
# by them. With nobody attached, polling the bus every few seconds and republishing every
# second is pure waste; both were among the daemon's largest costs.
# Sets KA_CLIENT_PRESENT, KA_DISCOVERY_INTERVAL, and KA_PUBLISH_INTERVAL and forks nothing:
# it is consulted on every loop wake, where a command substitution would cost more than
# the polling it is meant to avoid.
ka_service_discovery_interval() {
    local fast idle ttl seen='' now
    ka_tunable KEEPALIVE_DISCOVERY_INTERVAL 3;       fast=$REPLY
    ka_tunable KEEPALIVE_IDLE_DISCOVERY_INTERVAL 30; idle=$REPLY
    ka_tunable KEEPALIVE_CLIENT_PRESENCE_TTL 20;     ttl=$REPLY
    # Client presence alone decides. Keying this off the target count instead meant that
    # creating a single keep-alive pinned discovery to the fast cadence forever, even with
    # nothing attached to read the AVAILABLE rows it produces - which was the daemon's
    # single largest cost. Monitored targets are validated by health, not by discovery.
    [[ -r $KA_CLIENT_PRESENCE_FILE ]] && { read -r seen <"$KA_CLIENT_PRESENCE_FILE" || true; }
    # Only the leading digits count. TUIs from 1.0.0 append a terminal erase sequence to
    # the stamp, which a whole-line match rejected, so presence never registered. At most
    # twelve digits: epoch seconds need eleven for millennia, and a longer run would wrap
    # in Bash's 64-bit arithmetic and could read as a client seen moments ago.
    if [[ $seen =~ ^([0-9]{1,12})([^0-9]|$) ]]; then seen=${BASH_REMATCH[1]}; else seen=0; fi
    printf -v now '%(%s)T' -1
    if ((now - 10#$seen <= ttl)); then
        KA_CLIENT_PRESENT=1
        KA_DISCOVERY_INTERVAL=$fast
        KA_PUBLISH_INTERVAL=1
    else
        KA_CLIENT_PRESENT=0
        KA_DISCOVERY_INTERVAL=$idle
        # Every request republishes the index before it answers, and CLI commands refresh
        # first, so unattended the periodic copy only has to stay roughly current.
        ka_tunable KEEPALIVE_STATUS_INTERVAL 15
        KA_PUBLISH_INTERVAL=$REPLY
    fi
}

# Role: Summarize monitored targets for the loop's wake planning, without forking.
# Sets KA_SVC_ACTIVE when any countdown is running, KA_SVC_MONITORED when any target is not
# UNAVAILABLE, and KA_SVC_IDLE_DISCOVERY to the backends whose snapshot unattended health
# validation would actually reuse. A Konsole snapshot (10 s) never outlives the default idle
# discovery interval (30 s), so refreshing it with nobody watching only burned a full bus
# scan per pass; Orca's 35 s snapshot does span it and saves a live CLI call per target.
ka_service_scan_targets() {
    local uuid status konsole=0 orca=0 idle
    KA_SVC_ACTIVE=0
    KA_SVC_MONITORED=0
    KA_SVC_IDLE_DISCOVERY=()
    for uuid in "${KA_T_UUIDS[@]}"; do
        status=${KA_T_STATUS[$uuid]}
        [[ $status == UNAVAILABLE ]] && continue
        KA_SVC_MONITORED=1
        [[ $status == ACTIVE ]] && KA_SVC_ACTIVE=1
        case ${KA_T_BACKEND[$uuid]:-konsole} in
            konsole) konsole=1 ;;
            orca) orca=1 ;;
        esac
    done
    # A disabled backend cannot be discovered, so it must not plan wakeups for a pass.
    [[ ${KA_KONSOLE_ENABLED:-1} == 1 ]] || konsole=0
    [[ ${KA_ORCA_ENABLED:-0} == 1 ]] || orca=0
    ((konsole == 1 || orca == 1)) || return 0
    ka_tunable KEEPALIVE_IDLE_DISCOVERY_INTERVAL 30; idle=$REPLY
    if ((konsole == 1)); then
        ka_tunable KEEPALIVE_SNAPSHOT_MAX_AGE 10
        ((REPLY >= idle)) && KA_SVC_IDLE_DISCOVERY+=(konsole)
    fi
    if ((orca == 1)); then
        ka_tunable KEEPALIVE_ORCA_SNAPSHOT_MAX_AGE 35
        ((REPLY >= idle)) && KA_SVC_IDLE_DISCOVERY+=(orca)
    fi
    return 0
}

# Role: Choose the backends one periodic discovery pass refreshes, into KA_SVC_DISCOVER.
# Attended, every enabled backend; unattended, only those whose snapshot health reuses.
# Orca is skipped while it is backing off after outright failures, unless the most recent
# attempt - a client's REFRESH included - has since succeeded.
ka_service_discovery_backends() {
    local now=$1 backend
    local -a candidates=()
    KA_SVC_DISCOVER=()
    # A success on any path - a client's REFRESH included - ends the episode, so the next
    # failure starts again from the shortest delay.
    if [[ -z ${KA_ORCA_DISCOVERY_FAILURE-} ]]; then
        KA_ORCA_FAILURES=0
        KA_ORCA_RETRY_AT=0
    fi
    if ((KA_CLIENT_PRESENT == 1)); then
        [[ ${KA_KONSOLE_ENABLED:-1} == 1 ]] && candidates+=(konsole)
        [[ ${KA_ORCA_ENABLED:-0} == 1 ]] && candidates+=(orca)
    else
        candidates=("${KA_SVC_IDLE_DISCOVERY[@]}")
    fi
    for backend in "${candidates[@]}"; do
        if [[ $backend == orca && -n ${KA_ORCA_DISCOVERY_FAILURE-} ]] && ((now < KA_ORCA_RETRY_AT)); then
            continue
        fi
        KA_SVC_DISCOVER+=("$backend")
    done
    return 0
}

# Consecutive failed periodic Orca discovery passes, and when the next one may run.
KA_ORCA_FAILURES=0
KA_ORCA_RETRY_AT=0

# Role: Back off periodic Orca discovery exponentially, up to a minute, while it keeps failing.
# Every attempt starts the Electron-based CLI - about a quarter second of CPU - so a closed
# Orca app or an adapter-incompatible schema used to cost that every three seconds for as
# long as a client stayed attached. Snapshots are retained throughout, as for any failure.
ka_service_note_orca_discovery() {
    local now=$1 delay
    if [[ -z ${KA_ORCA_DISCOVERY_FAILURE-} ]]; then
        KA_ORCA_FAILURES=0
        KA_ORCA_RETRY_AT=0
        return 0
    fi
    ((KA_ORCA_FAILURES < 6)) && KA_ORCA_FAILURES=$((KA_ORCA_FAILURES + 1))
    delay=$((1 << KA_ORCA_FAILURES))
    ((delay > 60)) && delay=60
    KA_ORCA_RETRY_AT=$((now + delay))
}

# Longest the loop sleeps without a due task. It bounds how late the daemon notices a
# vanished runtime directory or a client that attached without sending a request.
KA_SERVICE_MAX_WAIT_MS=5000

# Role: Run the single-threaded daemon loop that interleaves IPC, timers, health, and discovery.
#
# The loop sleeps in the FIFO read until the earliest periodic task is due instead of
# polling five times a second; a request still wakes the read immediately. Anchors are whole
# monotonic seconds, so each due time is the start of a second and a task runs exactly when
# the integer comparisons below first pass. The one-second scheduler tick is planned only
# while a countdown is ACTIVE, because the tick's elapsed time is also how a suspend is
# detected: an unattended daemon with only paused targets has nothing to count down.
ka_service_loop() {
    local control_read=0 timeout wait_ms due now_ms ticking=0
    local now last_tick elapsed last_health last_discovery last_publish last_cleanup last_status
    local stale_logged=0 clock_warned=0 control_failures=0 last_flush=0 checkpoint_interval
    # Resolved once: these are process-wide settings, and validating them here keeps an
    # operator typo out of every arithmetic expression below.
    local health_interval status_interval cleanup_interval
    ka_tunable KEEPALIVE_HEALTH_INTERVAL 2;    health_interval=$REPLY
    ka_tunable KEEPALIVE_STATUS_INTERVAL 15;   status_interval=$REPLY
    ka_tunable KEEPALIVE_CLEANUP_INTERVAL 300; cleanup_interval=$REPLY
    ka_tunable KEEPALIVE_CHECKPOINT_INTERVAL 30; checkpoint_interval=$REPLY
    ka_now_monotonic_ms || { ka_error 'monotonic clock source is unavailable'; return 1; }
    last_tick=$((REPLY / 1000))
    last_health=$last_tick
    last_discovery=$last_tick
    last_publish=$last_tick
    last_cleanup=$last_tick
    last_status=$last_tick
    last_flush=$last_tick

    while true; do
        # Checked here, at the one point where no delivery or write is in progress. A
        # signal during the read below interrupts it at once, so stopping stays prompt.
        ka_service_honour_stop
        ka_service_discovery_interval
        ka_service_scan_targets
        # Captured before the wait: whether a countdown ran during it. A target that a
        # request activates mid-wait starts counting from the wake, not from the last tick.
        ticking=$KA_SVC_ACTIVE

        # With an unreadable clock this falls back to the old fixed pacing.
        wait_ms=200
        if ka_now_monotonic_ms; then
            now_ms=$REPLY
            due=$((last_status + status_interval))
            ((last_cleanup + cleanup_interval < due)) && due=$((last_cleanup + cleanup_interval))
            ((last_publish + KA_PUBLISH_INTERVAL < due)) && due=$((last_publish + KA_PUBLISH_INTERVAL))
            if ((KA_CLIENT_PRESENT == 1 || ${#KA_SVC_IDLE_DISCOVERY[@]} > 0)); then
                ((last_discovery + KA_DISCOVERY_INTERVAL < due)) && due=$((last_discovery + KA_DISCOVERY_INTERVAL))
            fi
            if ((KA_SVC_MONITORED == 1)); then
                ((last_health + health_interval < due)) && due=$((last_health + health_interval))
            fi
            if ((${#KA_T_DIRTY[@]} > 0)); then
                ((last_flush + checkpoint_interval < due)) && due=$((last_flush + checkpoint_interval))
            fi
            if ((ticking == 1)); then
                ((last_tick + 1 < due)) && due=$((last_tick + 1))
            fi
            # A few milliseconds past the boundary, so the wake lands inside the due second.
            wait_ms=$((due * 1000 - now_ms + 5))
            ((wait_ms > KA_SERVICE_MAX_WAIT_MS)) && wait_ms=$KA_SERVICE_MAX_WAIT_MS
            # Never zero: `read -t 0` polls without waiting, and an overdue task only
            # needs the shortest real wait before it runs below.
            ((wait_ms < 1)) && wait_ms=1
        fi
        printf -v timeout '%d.%03d' "$((wait_ms / 1000))" "$((wait_ms % 1000))"

        KA_SERVICE_WAITING=1
        ka_ipc_service_read "$timeout" && control_read=0 || control_read=$?
        KA_SERVICE_WAITING=0
        case $control_read in
            0)
                control_failures=0
                # shellcheck disable=SC2015  # C is `true`; this deliberately swallows both.
                [[ -n ${KA_IPC_LINE:-} ]] && ka_ipc_handle_line "$KA_IPC_LINE" || true
                ;;
            1)
                # Timeout: the planned wake.
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
            last_flush=$now
            continue
        elif ((elapsed > 0)); then
            # Without an ACTIVE countdown there is nothing to subtract, and a long planned
            # sleep must not be mistaken for a suspend gap on the next tick.
            ((ticking == 1)) && ka_service_try 'timer tick' ka_scheduler_tick "$elapsed"
            last_tick=$now
        fi

        if ((now - last_health >= health_interval)); then
            ka_service_try 'target validation' ka_state_validate_targets
            last_health=$now
        fi

        if ((now - last_discovery >= KA_DISCOVERY_INTERVAL)); then
            ka_service_discovery_backends "$now"
            if ((${#KA_SVC_DISCOVER[@]} > 0)); then
                # Not wrapped in ka_service_try: a non-zero return here means "the pass
                # hit its budget", which is a normal signal handled below, not a failure.
                if ka_state_refresh_discovery "${KA_SVC_DISCOVER[@]}"; then
                    stale_logged=0
                elif ((stale_logged == 0)); then
                    # The pass hit its budget, so the previous snapshot is retained. Warn
                    # once per episode rather than on every cycle.
                    ka_warn "${KA_DISCOVERY_STALE_BACKENDS:-terminal} discovery did not complete; using the previous backend snapshot"
                    stale_logged=1
                fi
                [[ " ${KA_SVC_DISCOVER[*]} " == *' orca '* ]] && ka_service_note_orca_discovery "$now"
            fi
            last_discovery=$now
        fi

        if ((now - last_publish >= KA_PUBLISH_INTERVAL)); then
            ka_service_try 'index publication' ka_state_publish_index
            last_publish=$now
        fi

        # Diagnostics only; clients read the index, not this file.
        if ((now - last_status >= status_interval)); then
            ka_service_try 'service status write' ka_service_write_status online
            last_status=$now
        fi

        if ((now - last_flush >= checkpoint_interval)); then
            ka_service_try 'checkpoint flush' ka_state_flush_dirty
            last_flush=$now
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

    ka_xdg_init || return 1
    ka_ensure_runtime_dirs || { ka_error 'runtime directory is not usable'; return 1; }
    ka_dbus_prepare_session_address
    ka_ensure_config_dirs || return 1
    ka_profile_init_defaults || return 1
    ka_now_monotonic || { ka_error 'a valid monotonic clock source (/proc/uptime by default) is required'; return 1; }
    command -v timeout >/dev/null 2>&1 || { ka_error 'GNU timeout is required for bounded terminal-backend calls'; return 1; }
    command -v flock >/dev/null 2>&1 || { ka_error 'flock is required for single-daemon locking'; return 1; }

    local konsole_setting orca_setting
    ka_service_backend_setting KEEPALIVE_KONSOLE_ENABLED; konsole_setting=$REPLY
    ka_service_backend_setting KEEPALIVE_ORCA_ENABLED; orca_setting=$REPLY
    KA_KONSOLE_ENABLED=0
    KA_ORCA_ENABLED=0
    if [[ $konsole_setting != 0 ]] && ka_qdbus_find; then
        KA_KONSOLE_ENABLED=1
        ka_dbus_send_find || ka_warn 'dbus-send not found; falling back to the slower qdbus transport'
        ka_dbus_use_send && ka_info "read-only D-Bus transport: $KA_DBUS_SEND"
    elif [[ $konsole_setting == 1 ]]; then
        ka_warn 'Konsole backend was requested but no qdbus executable was found'
    fi
    if [[ $orca_setting != 0 ]] && ka_orca_find; then
        KA_ORCA_ENABLED=1
        ka_info "Orca backend: $KA_ORCA_CLI (JSON: $KA_ORCA_JQ)"
    elif [[ $orca_setting == 1 ]]; then
        ka_warn 'Orca backend was requested but orca-ide and jq were not both available'
    fi
    if ((KA_KONSOLE_ENABLED == 0 && KA_ORCA_ENABLED == 0)); then
        ka_error 'no terminal backend is usable (install qdbus for Konsole, or orca-ide plus jq for Orca)'
        return 1
    fi
    ka_classifier_init
    ka_state_init_arrays
    # Another instance already owns the runtime state, so there is nothing for this one to
    # do. Exiting successfully keeps systemd from treating it as a failure and restarting
    # every RestartSec until the start limit trips.
    local lock_rc=0
    ka_service_acquire_lock || lock_rc=$?
    if ((lock_rc == 1)); then
        ka_info 'another Keep Alive service instance owns the runtime state; exiting quietly'
        return 0
    elif ((lock_rc != 0)); then
        return "$lock_rc"
    fi
    ka_ipc_service_open || { ka_error 'could not open the control FIFO'; return 1; }

    trap ka_service_cleanup EXIT
    trap 'ka_service_request_stop 130' INT
    trap 'ka_service_request_stop 143' TERM
    trap 'ka_service_request_stop 129' HUP

    # Sweep once at startup too; waiting a full interval leaves debris from the previous
    # daemon lifetime visible for no reason.
    ka_ipc_cleanup_stale
    ka_state_recover_target_messages \
        || { ka_error 'could not safely recover interrupted target message commits'; return 1; }
    ka_state_load_all_targets \
        || { ka_error 'could not quarantine every malformed runtime target'; return 1; }
    # Only discard stale staging debris after every rollback has either been recovered or
    # quarantined. Running this first could erase the sole valid copy of a message rotation.
    ka_cleanup_staged_dirs "$KA_RUNTIME_DIR"
    ka_state_sweep_temp_files
    if ! ka_state_refresh_discovery; then
        ka_warn "${KA_DISCOVERY_STALE_BACKENDS:-terminal} discovery was unavailable at startup; retaining empty/previous snapshots"
    fi
    ka_service_recover_targets || ka_warn 'one or more recovered targets could not be checkpointed'
    ka_state_publish_index || { ka_error 'could not publish the initial runtime index'; return 1; }
    ka_service_write_status online || { ka_error 'could not publish initial service status'; return 1; }
    ka_service_loop
}
