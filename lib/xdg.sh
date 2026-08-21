#!/usr/bin/env bash
# XDG path resolution and directory lifecycle helpers.

# Role: Resolve all Keep Alive XDG paths without creating them.
ka_xdg_init() {
    KA_CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
    KA_STATE_HOME=${XDG_STATE_HOME:-"$HOME/.local/state"}
    KA_RUNTIME_BASE=${XDG_RUNTIME_DIR:-"/tmp/keepalive-$UID"}

    KA_CONFIG_DIR="$KA_CONFIG_HOME/keepalive"
    KA_PROFILE_DIR="$KA_CONFIG_DIR/profile"
    KA_RUNTIME_DIR="$KA_RUNTIME_BASE/keepalive"
    KA_TARGETS_DIR="$KA_RUNTIME_DIR/targets"
    KA_DISCOVERY_DIR="$KA_RUNTIME_DIR/discovery"
    KA_REQUESTS_DIR="$KA_RUNTIME_DIR/requests"
    KA_RESPONSES_DIR="$KA_RUNTIME_DIR/responses"
    KA_LOGS_DIR="$KA_RUNTIME_DIR/logs"
    KA_CONTROL_FIFO="$KA_RUNTIME_DIR/control.fifo"
    KA_INDEX_FILE="$KA_RUNTIME_DIR/index.tsv"
    KA_SERVICE_STATE_FILE="$KA_RUNTIME_DIR/service.state"
}

# Role: Create private runtime directories used only for the current login session.
ka_ensure_runtime_dirs() {
    umask 077
    mkdir -p "$KA_RUNTIME_DIR" "$KA_TARGETS_DIR" "$KA_DISCOVERY_DIR" \
        "$KA_REQUESTS_DIR" "$KA_RESPONSES_DIR" "$KA_LOGS_DIR"
    chmod 700 "$KA_RUNTIME_DIR" "$KA_TARGETS_DIR" "$KA_DISCOVERY_DIR" \
        "$KA_REQUESTS_DIR" "$KA_RESPONSES_DIR" "$KA_LOGS_DIR" 2>/dev/null || true
}

# Role: Create the persistent configuration directory containing the single profile.
ka_ensure_config_dirs() {
    umask 077
    mkdir -p "$KA_PROFILE_DIR/messages"
    chmod 700 "$KA_CONFIG_DIR" "$KA_PROFILE_DIR" "$KA_PROFILE_DIR/messages" 2>/dev/null || true
}

# Role: Report whether the preferred user runtime directory is available.
ka_runtime_is_xdg() {
    [[ -n ${XDG_RUNTIME_DIR:-} && -d ${XDG_RUNTIME_DIR:-} ]]
}
