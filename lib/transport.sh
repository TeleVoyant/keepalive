#!/usr/bin/env bash
# Backend-neutral validation and delivery dispatch for managed terminal targets.

# Role: Return a target's persisted backend, treating pre-backend checkpoints as Konsole.
ka_transport_backend() {
    local uuid=$1
    REPLY=${KA_T_BACKEND[$uuid]:-konsole}
}

# Role: Validate one target through its backend adapter immediately before use.
ka_transport_validate_target() {
    local uuid=$1
    ka_transport_backend "$uuid"
    case $REPLY in
        konsole)
            ka_konsole_validate_target "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" "$uuid" \
                "${KA_T_TERM_PID[$uuid]}" "${KA_T_AI_PID[$uuid]}" "${KA_T_AI_START[$uuid]}"
            ;;
        orca)
            ka_orca_validate_target "${KA_T_ORCA_HANDLE[$uuid]}" "${KA_T_ORCA_PTY[$uuid]}" \
                "${KA_T_ORCA_INCARNATION[$uuid]}" "${KA_T_ORCA_WORKTREE[$uuid]}" \
                "${KA_T_ORCA_RUNTIME[$uuid]}" "${KA_T_ORCA_HOST[$uuid]}" \
                "${KA_T_ORCA_TAB[$uuid]}" "${KA_T_ORCA_LEAF[$uuid]}" \
                "${KA_T_ORCA_AGENT[$uuid]}"
            ;;
        *) return 22 ;;
    esac
}

# Role: Translate a backend validation result into an operator-facing reason.
ka_transport_validation_reason() {
    local backend=$1 rc=$2
    case $backend in
        konsole) ka_konsole_validation_reason "$rc" ;;
        orca) ka_orca_validation_reason "$rc" ;;
        *) printf 'Unknown terminal backend: %s' "$backend" ;;
    esac
}

# Role: Report whether a backend validation result is transient rather than identity loss.
ka_transport_validation_is_transient() {
    local backend=$1 rc=$2
    case $backend in
        konsole) ka_konsole_validation_is_transient "$rc" ;;
        orca) ka_orca_validation_is_transient "$rc" ;;
        *) return 1 ;;
    esac
}

# Role: Report whether one transient result counts toward sticky-unavailable debouncing.
ka_transport_validation_consumes_strike() {
    local backend=$1 rc=$2
    case $backend in
        konsole) return 0 ;;
        orca) ka_orca_validation_consumes_strike "$rc" ;;
        *) return 1 ;;
    esac
}

# Role: Deliver one event through the target's selected terminal backend.
ka_transport_deliver() {
    local uuid=$1 mode=$2 message=${3-} submit_only=${4:-0}
    ka_transport_backend "$uuid"
    case $REPLY in
        konsole)
            ka_konsole_deliver "${KA_T_SERVICE[$uuid]}" "${KA_T_PATH[$uuid]}" \
                "$mode" "$message" "$submit_only"
            ;;
        orca)
            ka_orca_deliver "${KA_T_ORCA_HANDLE[$uuid]}" "$mode" "$message" "$submit_only"
            ;;
        *) return 2 ;;
    esac
}

# Role: Build a backend-specific transport failure message in REPLY.
ka_transport_failure_reason() {
    local uuid=$1 event=$2 label
    ka_transport_backend "$uuid"
    case $REPLY in
        konsole) label='Konsole' ;;
        orca) label='Orca' ;;
        *) label='Terminal backend' ;;
    esac
    REPLY="$label rejected the $event send (transport failure)"
}
