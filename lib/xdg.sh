#!/usr/bin/env bash
# XDG path resolution and directory lifecycle helpers.

# Role: Accept only an absolute, owned, non-symlink runtime directory.
ka_runtime_candidate_is_safe() {
    local path=${1:-} normalized canonical mode
    REPLY=''
    [[ $path == /* ]] || return 1
    normalized=$path
    while [[ $normalized != / && $normalized == */ ]]; do normalized=${normalized%/}; done
    canonical=$(readlink -f -- "$normalized") || return 1
    [[ $canonical == "$normalized" && -d $canonical && ! -L $canonical && -O $canonical ]] || return 1
    mode=$(stat -Lc '%a' -- "$canonical") || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] || return 1
    (((8#$mode & 077) == 0)) || return 1
    REPLY=$canonical
}

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
    KA_RUNTIME_REJECTED=''
    if [[ -n ${XDG_RUNTIME_DIR:-} ]] && ka_runtime_candidate_is_safe "$XDG_RUNTIME_DIR"; then
        KA_RUNTIME_BASE=$REPLY
        KA_RUNTIME_SOURCE=xdg
        return 0
    fi
    [[ -z ${XDG_RUNTIME_DIR:-} ]] || KA_RUNTIME_REJECTED=$XDG_RUNTIME_DIR
    # Overridable so tests can exercise the precedence without depending on whether the
    # host happens to have a user-manager runtime directory.
    local per_user=${KEEPALIVE_PER_USER_RUNTIME:-"/run/user/$UID"}
    if ka_runtime_candidate_is_safe "$per_user"; then
        KA_RUNTIME_BASE=$REPLY
        KA_RUNTIME_SOURCE=per-user
        return 0
    fi
    KA_RUNTIME_BASE="/tmp/keepalive-$UID"
    KA_RUNTIME_SOURCE=fallback
}

# Per-process memo for the configuration-path checks below. Every CLI/TUI start validates
# the same few ancestors for several nested directories; without it one `keepalive list`
# spawned hundreds of stat/id/getent processes. A cached entry only skips the external
# metadata lookups: the fork-free symlink and directory tests still run on every call.
declare -gA KA_CONFIG_SAFE_DIR=() KA_CONFIG_PRIVATE_GID=()

# Role: Accept group write only for the current user's private primary group.
# The result is cached per gid for the life of the process.
ka_directory_group_is_private() {
    local gid=$1 user_name group_record group_name group_gid group_members passwd_records verdict=0
    local passwd_name passwd_password passwd_uid passwd_gid passwd_gecos passwd_home passwd_shell
    if [[ -n ${KA_CONFIG_PRIVATE_GID[$gid]+x} ]]; then
        return "${KA_CONFIG_PRIVATE_GID[$gid]}"
    fi
    # GROUPS[0] is the primary gid, so only a matching directory needs the lookups.
    if [[ $gid != "${GROUPS[0]-}" ]]; then
        verdict=1
    elif ! user_name=$(id -un) || ! group_record=$(getent group "$gid"); then
        verdict=1
    else
        IFS=: read -r group_name _ group_gid group_members <<<"$group_record"
        if [[ $group_name != "$user_name" || $group_gid != "$gid" || -n $group_members ]]; then
            verdict=1
        elif ! passwd_records=$(getent passwd); then
            verdict=1
        else
            while IFS=: read -r passwd_name passwd_password passwd_uid passwd_gid passwd_gecos passwd_home passwd_shell; do
                if [[ $passwd_gid == "$gid" && $passwd_name != "$user_name" ]]; then
                    verdict=1
                    break
                fi
            done <<<"$passwd_records"
        fi
    fi
    KA_CONFIG_PRIVATE_GID[$gid]=$verdict
    return "$verdict"
}

# Role: Validate canonical configuration components and the permitted private-group policy.
# XDG roots are canonicalized before this call, so a symlink here is a newly planted
# component below the selected root and is rejected. Every existing component is tested
# with -L, so a path that passes is already canonical; the ownership/mode metadata of the
# components not yet seen in this process is read with a single stat.
ka_config_components_are_safe() {
    local path=${1:-} normalized current component remaining
    local -a pending=() records=()
    local record owner mode group mode_bits sticky_exception index
    [[ $path == /* ]] || return 1
    normalized=$path
    while [[ $normalized != / && $normalized == */ ]]; do normalized=${normalized%/}; done
    remaining=${normalized#/}
    current=/
    while [[ -n $remaining ]]; do
        component=${remaining%%/*}
        if [[ $remaining == */* ]]; then
            remaining=${remaining#*/}
        else
            remaining=''
        fi
        [[ -n $component && $component != . && $component != .. ]] || return 1
        if [[ $current == / ]]; then current="/$component"; else current="$current/$component"; fi
        [[ -L $current ]] && return 1
        [[ -e $current ]] || break
        [[ -d $current ]] || return 1
        [[ -n ${KA_CONFIG_SAFE_DIR[$current]+x} ]] || pending+=("$current")
    done
    if ((${#pending[@]} > 0)); then
        mapfile -t records < <(stat -Lc '%u %a %g' -- "${pending[@]}" 2>/dev/null)
        ((${#records[@]} == ${#pending[@]})) || return 1
        for index in "${!pending[@]}"; do
            current=${pending[index]}
            read -r owner mode group <<<"${records[index]}"
            [[ $owner == "$EUID" || $owner == 0 ]] || return 1
            [[ $mode =~ ^[0-7]{3,4}$ && $group =~ ^[0-9]+$ ]] || return 1
            mode_bits=$((8#$mode))
            sticky_exception=0
            if (( owner == 0 && (mode_bits & 01000) != 0 )) \
                && [[ $current != "$normalized" ]]; then
                sticky_exception=1
            fi
            (( (mode_bits & 0002) == 0 || sticky_exception == 1 )) || return 1
            if (( (mode_bits & 0020) != 0 && sticky_exception == 0 )) \
                && ! ka_directory_group_is_private "$group"; then
                return 1
            fi
            # A sticky exception is position-dependent (never the final directory), and
            # the final directory must be this user's; only cache what holds anywhere.
            if ((sticky_exception == 0)) && [[ $owner == "$EUID" ]]; then
                KA_CONFIG_SAFE_DIR[$current]=1
            elif [[ $current == "$normalized" ]]; then
                return 1
            else
                # Root-owned (or root sticky) ancestors: safe above a selected directory,
                # never as the directory itself.
                KA_CONFIG_SAFE_DIR[$current]=2
            fi
        done
    fi
    [[ ${KA_CONFIG_SAFE_DIR[$normalized]-} == 1 || ! -e $normalized ]] || return 1
    REPLY=$normalized
}

# Role: Create one configuration directory without following a pre-existing symlink.
ka_config_prepare_dir() {
    local path=$1
    ka_config_components_are_safe "$path" || {
        ka_error "refusing unsafe configuration directory: $path"
        return 1
    }
    if [[ -L $path || (-e $path && ! -d $path) ]]; then
        ka_error "configuration path is not a real directory: $path"
        return 1
    fi
    if [[ ! -e $path ]]; then
        mkdir -- "$path" || { ka_error "could not create configuration directory: $path"; return 1; }
    fi
    ka_config_components_are_safe "$path" || {
        ka_error "configuration directory became unsafe: $path"
        return 1
    }
}

# Role: Resolve all Keep Alive XDG paths without creating them.
ka_xdg_init() {
    # Set once here so atomic writes need no per-file chmod fork. KA_PRIVATE_UMASK
    # records that promise for ka_atomic_temp; nothing else in the tool changes umask.
    umask 077
    KA_PRIVATE_UMASK=1
    local configured_config canonical_config
    KA_CONFIG_SAFE_DIR=() KA_CONFIG_PRIVATE_GID=()
    # runtime-only: the read-only status reader needs no configuration and must work
    # where HOME is unset; the config paths are then left empty.
    if [[ ${1-} == runtime-only ]]; then
        KA_CONFIG_HOME='' KA_CONFIG_DIR='' KA_PROFILE_DIR=''
        ka_xdg_resolve_runtime_base
        ka_xdg_set_runtime_paths
        return 0
    fi
    if [[ -n ${XDG_CONFIG_HOME:-} ]]; then
        [[ $XDG_CONFIG_HOME == /* ]] || { ka_error 'XDG_CONFIG_HOME must be an absolute path'; return 1; }
        configured_config=$XDG_CONFIG_HOME
    else
        [[ ${HOME:-} == /* ]] || { ka_error 'HOME must be an absolute path when XDG_CONFIG_HOME is unset'; return 1; }
        configured_config="$HOME/.config"
    fi
    canonical_config=$(readlink -f -- "$configured_config") || {
        ka_error 'could not canonicalize XDG_CONFIG_HOME'
        return 1
    }
    ka_config_components_are_safe "$canonical_config" || {
        ka_error 'XDG_CONFIG_HOME must resolve to an owned, safely permissioned directory path'
        return 1
    }
    KA_CONFIG_HOME=$REPLY
    ka_xdg_resolve_runtime_base

    KA_CONFIG_DIR="$KA_CONFIG_HOME/keepalive"
    KA_PROFILE_DIR="$KA_CONFIG_DIR/profile"
    ka_xdg_set_runtime_paths
}

# Role: Derive every runtime path from the resolved KA_RUNTIME_BASE.
ka_xdg_set_runtime_paths() {
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

# Role: Create or validate one owned private directory without following a child symlink.
ka_runtime_prepare_dir() {
    local path=$1 canonical
    if [[ -L $path || (-e $path && ! -d $path) ]]; then
        ka_error "refusing unsafe runtime directory: $path"
        return 1
    fi
    if [[ ! -e $path ]]; then
        mkdir -- "$path" || { ka_error "could not create runtime directory: $path"; return 1; }
    fi
    [[ -d $path && ! -L $path && -O $path ]] \
        || { ka_error "runtime directory is not an owned real directory: $path"; return 1; }
    canonical=$(readlink -f -- "$path") \
        || { ka_error "could not canonicalize runtime directory: $path"; return 1; }
    [[ $canonical == "$path" ]] \
        || { ka_error "refusing runtime directory through a symlink: $path"; return 1; }
    chmod 700 "$path" 2>/dev/null \
        || { ka_error "could not secure runtime directory: $path"; return 1; }
}

# Role: Create private runtime directories used only for the current login session.
ka_ensure_runtime_dirs() {
    local path
    umask 077
    ka_runtime_secure || return 1
    # Build one level at a time. A single mkdir -p would follow a pre-created
    # keepalive/targets (or sibling) symlink below an otherwise trusted runtime base.
    ka_runtime_prepare_dir "$KA_RUNTIME_DIR" || return 1
    for path in "$KA_TARGETS_DIR" "$KA_QUARANTINE_DIR" "$KA_REQUESTS_DIR" \
        "$KA_RESPONSES_DIR" "$KA_LOGS_DIR"; do
        ka_runtime_prepare_dir "$path" || return 1
    done
}

# Role: Create the persistent configuration directory containing the single profile.
ka_ensure_config_dirs() {
    umask 077
    # The memo spans one operation: a long-lived daemon re-runs this for profile updates,
    # and a directory whose mode changed since must be judged afresh.
    KA_CONFIG_SAFE_DIR=() KA_CONFIG_PRIVATE_GID=()
    # Usually the whole tree already exists: validating the deepest path first reads every
    # ancestor's metadata in one stat, so the per-level checks below are memo hits. A
    # failure here is not final - the per-level checks report the precise problem.
    ka_config_components_are_safe "$KA_PROFILE_DIR/messages" >/dev/null 2>&1 || true
    ka_config_prepare_dir "$KA_CONFIG_HOME" || return 1
    [[ ! -L $KA_CONFIG_DIR && (! -e $KA_CONFIG_DIR || -d $KA_CONFIG_DIR) ]] || {
        ka_error "configuration path is not a real directory: $KA_CONFIG_DIR"
        return 1
    }
    ka_recover_staged_dir "$KA_PROFILE_DIR" || return 1
    ka_config_prepare_dir "$KA_CONFIG_DIR" || return 1
    ka_config_prepare_dir "$KA_PROFILE_DIR" || return 1
    ka_config_prepare_dir "$KA_PROFILE_DIR/messages" || return 1
    chmod 700 "$KA_CONFIG_DIR" "$KA_PROFILE_DIR" "$KA_PROFILE_DIR/messages" 2>/dev/null \
        || { ka_error "could not secure configuration directories under $KA_CONFIG_DIR"; return 1; }
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
    chmod 700 "$base" 2>/dev/null \
        || { ka_error "could not secure runtime base: $base"; return 1; }
    ka_warn "no session runtime directory found; using $base, which does not share the login session lifecycle"
    return 0
}
