#!/usr/bin/env bash
# XDG path resolution and directory lifecycle helpers.

# Role: Choose the runtime base directory and record how it was chosen.
#
# Precedence, most trustworthy first:
#   1. $XDG_RUNTIME_DIR   the login session's own directory.
#   2. /run/user/$UID     the same directory the user manager uses. Contexts that never
#                         run pam_systemd - su, sudo -u, cron, non-interactive remote
#                         exec - inherit no XDG_RUNTIME_DIR, and without this step a
#                         client there silently addresses a different directory from the
#                         running daemon and reports the service as unavailable.
#   3. /tmp/keepalive-UID last resort, hardened by ka_runtime_secure.
#
# KA_RUNTIME_SOURCE is what lets doctor explain which one is in use.
ka_xdg_resolve_runtime_base() {
    if [[ -n ${XDG_RUNTIME_DIR:-} && -d ${XDG_RUNTIME_DIR:-} ]]; then
        KA_RUNTIME_BASE=$XDG_RUNTIME_DIR
        KA_RUNTIME_SOURCE=xdg
        return 0
    fi
    # Overridable so tests can exercise the precedence without depending on whether the
    # host happens to have a user-manager runtime directory.
    local per_user=${KEEPALIVE_PER_USER_RUNTIME:-"/run/user/$UID"}
    if [[ -d $per_user && ! -L $per_user && -O $per_user ]]; then
        KA_RUNTIME_BASE=$per_user
        KA_RUNTIME_SOURCE=per-user
        return 0
    fi
    KA_RUNTIME_BASE="/tmp/keepalive-$UID"
    KA_RUNTIME_SOURCE=fallback
}

# Role: Resolve all Keep Alive XDG paths without creating them.
ka_xdg_init() {
    # Set once here so atomic writes need no per-file chmod fork.
    umask 077
    KA_CONFIG_HOME=${XDG_CONFIG_HOME:-"$HOME/.config"}
    ka_xdg_resolve_runtime_base

    KA_CONFIG_DIR="$KA_CONFIG_HOME/keepalive"
    KA_PROFILE_DIR="$KA_CONFIG_DIR/profile"
    KA_RUNTIME_DIR="$KA_RUNTIME_BASE/keepalive"
    KA_TARGETS_DIR="$KA_RUNTIME_DIR/targets"
    KA_QUARANTINE_DIR="$KA_RUNTIME_DIR/quarantine"
    KA_REQUESTS_DIR="$KA_RUNTIME_DIR/requests"
    KA_RESPONSES_DIR="$KA_RUNTIME_DIR/responses"
    KA_LOGS_DIR="$KA_RUNTIME_DIR/logs"
    KA_CONTROL_FIFO="$KA_RUNTIME_DIR/control.fifo"
    KA_INDEX_FILE="$KA_RUNTIME_DIR/index.tsv"
    KA_SERVICE_STATE_FILE="$KA_RUNTIME_DIR/service.state"
    KA_CLIENT_PRESENCE_FILE="$KA_RUNTIME_DIR/clients.seen"
}

# Role: Create private runtime directories used only for the current login session.
ka_ensure_runtime_dirs() {
    umask 077
    ka_runtime_secure || return 1
    mkdir -p "$KA_RUNTIME_DIR" "$KA_TARGETS_DIR" "$KA_QUARANTINE_DIR" \
        "$KA_REQUESTS_DIR" "$KA_RESPONSES_DIR" "$KA_LOGS_DIR"
    chmod 700 "$KA_RUNTIME_DIR" "$KA_TARGETS_DIR" "$KA_QUARANTINE_DIR" \
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

# Role: Refuse to use an unsafe runtime base, and harden the predictable /tmp fallback.
# Only the /tmp fallback needs this: the other two candidates are already session-managed
# directories that ka_xdg_resolve_runtime_base has verified. /tmp/keepalive-$UID is a name
# any local process can guess and pre-create, so it is checked for a symlink and for
# ownership before use. `-O` is an ownership test that needs no fork.
ka_runtime_secure() {
    [[ ${KA_RUNTIME_SOURCE:-fallback} == fallback ]] || return 0
    local base=$KA_RUNTIME_BASE
    if [[ -L $base ]]; then
        ka_error "refusing to use runtime base through a symlink: $base"
        return 1
    fi
    if [[ -e $base ]]; then
        if [[ ! -d $base || ! -O $base ]]; then
            ka_error "runtime base exists but is not a directory owned by this user: $base"
            return 1
        fi
    else
        mkdir -p "$base" || { ka_error "could not create runtime base: $base"; return 1; }
    fi
    chmod 700 "$base" 2>/dev/null || true
    ka_warn "no session runtime directory found; using $base, which does not share the login session lifecycle"
    return 0
}
