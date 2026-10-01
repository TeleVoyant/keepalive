#!/usr/bin/env bash
# Install Keep Alive Manager for the current user only; root is intentionally unsupported.
set -Eeuo pipefail

INSTALL_STAGE=''
INSTALL_BACKUP=''
INSTALL_UNIT_BACKUP=''
INSTALL_SHARE=''
INSTALL_UNITS=''
INSTALL_LINK=''
INSTALL_OLD_LINK_TARGET=''
INSTALL_HAD_SHARE=0
INSTALL_HAD_LINK=0
INSTALL_BACKUP_CREATED=0
INSTALL_NEW_SHARE_LIVE=0
INSTALL_OLD_SOCKET_ENABLE_STATE=''
INSTALL_OLD_SOCKET_ACTIVE=0
INSTALL_OLD_SERVICE_ENABLE_STATE=''
INSTALL_OLD_SERVICE_ACTIVE=0
INSTALL_ROLLBACK_ARMED=0
INSTALL_MANAGED_LINKS=(
    sockets.target.wants/keepalive.socket
    sockets.target.wants/keepalive.service
    graphical-session.target.wants/keepalive.socket
    graphical-session.target.wants/keepalive.service
)

# Role: Print an installer error and terminate cleanly.
die() { printf 'install: ERROR: %s\n' "$*" >&2; exit 1; }

# Role: Resolve the project root from this installer location.
project_root() {
    local self
    self=$(readlink -f -- "${BASH_SOURCE[0]}")
    printf '%s' "${self%/scripts/install.sh}"
}

# Role: Canonicalize an absolute path lexically and through any existing symlink parents.
canonical_path() {
    local path=$1 canonical
    [[ $path == /* ]] || return 1
    canonical=$(readlink -m -- "$path") || return 1
    [[ $canonical == /* ]] || return 1
    REPLY=$canonical
}

# Role: Return true when one canonical path is equal to or nested below another.
path_is_within() {
    local path=$1 parent=$2
    [[ $path == "$parent" || $path == "$parent/"* ]]
}

# Role: Return true when either canonical path contains the other.
paths_overlap() {
    path_is_within "$1" "$2" || path_is_within "$2" "$1"
}

# Role: Put the live daemon runtime directory for this login in REPLY.
# Mirrors the daemon's normal resolution; an unusual fallback location simply yields no
# targets here, which only skips the reload report, never the installation.
install_runtime_dir() {
    REPLY="${XDG_RUNTIME_DIR:-/run/user/$EUID}/keepalive"
}

# Role: Print "uuid<TAB>status" for every monitored target checkpoint in a runtime directory.
# Read with builtins only from owned, non-symlink files; this is a report, not a recovery.
# A checkpoint that cannot be read is still listed, as UNREADABLE under its directory name,
# so that losing it in the restart is reported rather than silently never counted.
install_target_manifest() {
    local runtime=$1 dir state key value uuid status
    [[ -d $runtime/targets && ! -L $runtime/targets ]] || return 0
    for dir in "$runtime"/targets/*; do
        state=$dir/state.tsv
        [[ -d $dir && ! -L $dir && -O $dir && -f $state && ! -L $state && -O $state ]] || continue
        if [[ ! -r $state ]]; then
            printf '%s\tUNREADABLE\n' "${dir##*/}"
            continue
        fi
        uuid=''
        status=''
        { while IFS=$'\t' read -r key value _; do
            case $key in
                uuid) uuid=$value ;;
                status) status=$value ;;
            esac
        done <"$state"; } 2>/dev/null || true
        if [[ -n $uuid && -n $status ]]; then
            printf '%s\t%s\n' "$uuid" "$status"
        else
            printf '%s\tUNREADABLE\n' "${dir##*/}"
        fi
    done
    return 0
}

# Role: Put the pid of the daemon that owns a runtime directory in REPLY, or fail.
# A published pid is only a hint: it can be stale and reused. The proof is ownership plus
# an open descriptor on this runtime's manager.lock, which only the daemon that owns the
# runtime holds - however it was invoked, and never an unrelated process.
install_running_daemon_pid() {
    local runtime=$1 key value pid='' state='' fd
    REPLY=''
    [[ -f $runtime/service.state && ! -L $runtime/service.state && -r $runtime/service.state ]] \
        || return 1
    { while IFS=$'\t' read -r key value _; do
        case $key in
            pid) pid=$value ;;
            state) state=$value ;;
        esac
    done <"$runtime/service.state"; } 2>/dev/null || true
    [[ $state == online && $pid =~ ^[0-9]+$ && -d /proc/$pid && -O /proc/$pid ]] || return 1
    [[ -f $runtime/manager.lock ]] || return 1
    for fd in /proc/"$pid"/fd/*; do
        # -ef follows the descriptor's magic link and compares inodes: exact, and immune
        # to how either path is spelled.
        if [[ $fd -ef $runtime/manager.lock ]]; then
            REPLY=$pid
            return 0
        fi
    done
    return 1
}

# Role: Wait until a daemon other than the given pid reports itself online after a restart.
# Recovery revalidates every target live before the daemon reports online, which can take
# a while on a slow bus, so the wait is generous; it ends early if the unit has failed.
install_wait_for_new_daemon() {
    local runtime=$1 old_pid=$2 tries
    for ((tries = 0; tries < 300; tries++)); do
        if install_running_daemon_pid "$runtime" && [[ $REPLY != "$old_pid" ]]; then
            return 0
        fi
        if ((tries % 25 == 24)) && systemctl --user is-failed --quiet keepalive.service 2>/dev/null; then
            return 1
        fi
        sleep 0.2
    done
    return 1
}

# Role: Report whether every keep-alive monitored before the update came back afterwards.
# Recovery publishes the index before the daemon reports itself online, so the index then
# lists exactly the targets the new code loaded, with their recovered states.
install_report_reload() {
    local runtime=$1 manifest=$2 uuid status line now_status loaded=0 changed=0
    local -A after=()
    local -a missing=()
    if [[ -f $runtime/index.tsv && ! -L $runtime/index.tsv && -r $runtime/index.tsv ]]; then
        { while IFS= read -r line; do
            # Positional, not `read`: tab is IFS whitespace, so `read` would merge an empty
            # name or directory column and shift the status out of place.
            uuid=${line%%$'\t'*}
            now_status=${line#*$'\t'}; now_status=${now_status#*$'\t'}
            now_status=${now_status#*$'\t'}; now_status=${now_status#*$'\t'}
            now_status=${now_status%%$'\t'*}
            [[ -n $uuid ]] && after[$uuid]=$now_status
        done <"$runtime/index.tsv"; } 2>/dev/null || true
    fi
    while IFS=$'\t' read -r uuid status; do
        [[ -n $uuid ]] || continue
        if [[ -z ${after[$uuid]+x} || ${after[$uuid]} == AVAILABLE ]]; then
            missing+=("$uuid ($status)")
            continue
        fi
        loaded=$((loaded + 1))
        if [[ ${after[$uuid]} != "$status" ]]; then
            changed=$((changed + 1))
            printf 'Keep-alive %s was %s and is now %s after the restart.\n' \
                "$uuid" "$status" "${after[$uuid]}"
        fi
    done <<<"$manifest"
    printf 'Reloaded %d running keep-alive(s) on the updated daemon.\n' "$loaded"
    if ((${#missing[@]} > 0)); then
        printf 'install: warning: %d keep-alive(s) did not come back after the restart:\n' \
            "${#missing[@]}" >&2
        printf 'install: warning:   %s\n' "${missing[@]}" >&2
        printf 'install: warning: check %s/quarantine and run: keepalive doctor\n' "$runtime" >&2
    fi
    return 0
}

# Role: Classify a systemd unit as active or safely inactive without swallowing probe errors.
unit_active_state() {
    local unit=$1 state rc
    if state=$(systemctl --user is-active "$unit" 2>/dev/null); then
        REPLY=active
        return 0
    else
        rc=$?
    fi
    case "$state:$rc" in
        inactive:3|failed:3|unknown:4)
            REPLY=inactive
            return 0
            ;;
    esac
    return "$rc"
}

# Role: Record only real persistent/runtime enablement, excluding static unit status.
unit_enable_state() {
    local unit=$1 state rc
    if state=$(systemctl --user is-enabled "$unit" 2>/dev/null); then
        rc=0
    else
        rc=$?
    fi
    case $state in
        enabled|enabled-runtime)
            REPLY=$state
            return 0
            ;;
        disabled|static|indirect|generated|transient|alias|linked|linked-runtime|masked|masked-runtime|not-found)
            REPLY=''
            return 0
            ;;
    esac
    ((rc == 0)) && return 1
    return "$rc"
}

# Role: Accept only an absolute, owned runtime path with no symlinked components.
runtime_dir_is_safe() {
    local path=${1:-} normalized canonical mode
    [[ $path == /* ]] || return 1
    normalized=$path
    while [[ $normalized != / && $normalized == */ ]]; do normalized=${normalized%/}; done
    canonical=$(readlink -f -- "$normalized") || return 1
    [[ $canonical == "$normalized" && -d $canonical && ! -L $canonical && -O $canonical ]] || return 1
    mode=$(stat -Lc '%a' -- "$canonical") || return 1
    [[ $mode =~ ^[0-7]{3,4}$ ]] || return 1
    (((8#$mode & 077) == 0))
}

# Role: Recover the standard systemd user-runtime path when a shell omitted or corrupted it.
prepare_user_manager_environment() {
    if [[ -n ${XDG_RUNTIME_DIR:-} ]] && ! runtime_dir_is_safe "$XDG_RUNTIME_DIR"; then
        unset XDG_RUNTIME_DIR
    fi
    if [[ -z ${XDG_RUNTIME_DIR:-} ]] && runtime_dir_is_safe "/run/user/$UID"; then
        export XDG_RUNTIME_DIR="/run/user/$UID"
    fi
}

# Role: Reject directory-shaped reserved link paths before any link cleanup begins.
validate_managed_unit_links() {
    local unit_root=$1 relative path
    for relative in "${INSTALL_MANAGED_LINKS[@]}"; do
        path="$unit_root/$relative"
        [[ ! -d $path || -L $path ]] || return 1
    done
}

# Role: Remove every enablement link created by current or legacy Keep Alive releases.
remove_managed_unit_links() {
    local unit_root=$1 relative
    validate_managed_unit_links "$unit_root" || return 1
    for relative in "${INSTALL_MANAGED_LINKS[@]}"; do
        rm -f -- "$unit_root/$relative" || return 1
    done
}

# Role: Recognize a current or legacy managed source tree before replacing it recursively.
installed_share_is_managed() {
    local share=$1
    [[ -d $share && ! -L $share \
        && -f $share/keepalive && ! -L $share/keepalive \
        && -f $share/scripts/uninstall.sh && ! -L $share/scripts/uninstall.sh \
        && -f $share/systemd/keepalive.service && ! -L $share/systemd/keepalive.service \
        && -f $share/systemd/keepalive.socket && ! -L $share/systemd/keepalive.socket ]]
}

# Role: Snapshot current persistent enablement links for exact transaction rollback.
snapshot_managed_unit_links() {
    local unit_root=$1 relative source destination
    validate_managed_unit_links "$unit_root" || return 1
    for relative in "${INSTALL_MANAGED_LINKS[@]}"; do
        source="$unit_root/$relative"
        [[ -e $source || -L $source ]] || continue
        destination="$INSTALL_UNIT_BACKUP/links/$relative"
        mkdir -p -- "${destination%/*}" || return 1
        cp -a -- "$source" "$destination" || return 1
    done
}

# Role: Replace transaction-created persistent links with their exact pre-install forms.
restore_managed_unit_links() {
    local relative backup destination
    remove_managed_unit_links "$INSTALL_UNITS" || return 1
    for relative in "${INSTALL_MANAGED_LINKS[@]}"; do
        backup="$INSTALL_UNIT_BACKUP/links/$relative"
        [[ -e $backup || -L $backup ]] || continue
        destination="$INSTALL_UNITS/$relative"
        mkdir -p -- "${destination%/*}" || return 1
        cp -a -- "$backup" "$destination" || return 1
    done
}

# Role: Copy one unit through a same-directory temporary file for atomic replacement.
install_unit_file() {
    local source=$1 destination=$2
    local temporary
    temporary=$(mktemp "${destination}.new.XXXXXX") || return 1
    cp -f -- "$source" "$temporary" || { rm -f -- "$temporary"; return 1; }
    chmod 0644 "$temporary" || { rm -f -- "$temporary"; return 1; }
    mv -fT -- "$temporary" "$destination" || { rm -f -- "$temporary"; return 1; }
}

# Role: Restore one pre-install unit file, or its prior absence, during rollback.
restore_unit_file() {
    local name=$1 destination="$INSTALL_UNITS/$1"
    [[ ! -d $destination || -L $destination ]] || return 1
    rm -f -- "$destination" || return 1
    if [[ -e $INSTALL_UNIT_BACKUP/$name || -L $INSTALL_UNIT_BACKUP/$name ]]; then
        cp -a -- "$INSTALL_UNIT_BACKUP/$name" "$destination" || return 1
    fi
}

# Role: Clean staging files and roll a failed upgrade back to its prior usable installation.
finish_install() {
    local rc=$? rollback_failed=0
    trap - EXIT
    if ((rc != 0 && INSTALL_ROLLBACK_ARMED == 1)); then
        printf 'install: update failed; restoring the previous installation\n' >&2
        if ((INSTALL_NEW_SHARE_LIVE == 1)); then
            rm -rf -- "$INSTALL_SHARE" || rollback_failed=1
        fi
        if ((INSTALL_BACKUP_CREATED == 1)) && [[ -e $INSTALL_BACKUP/tree ]]; then
            mv -T -- "$INSTALL_BACKUP/tree" "$INSTALL_SHARE" || rollback_failed=1
        fi
        restore_unit_file keepalive.service || rollback_failed=1
        restore_unit_file keepalive.socket || rollback_failed=1
        if ((INSTALL_HAD_LINK == 1)); then
            ln -sfn -- "$INSTALL_OLD_LINK_TARGET" "$INSTALL_LINK" || rollback_failed=1
        else
            rm -f -- "$INSTALL_LINK" || rollback_failed=1
        fi
        systemctl --user stop keepalive.service keepalive.socket >/dev/null 2>&1 || rollback_failed=1
        systemctl --user disable keepalive.socket keepalive.service >/dev/null 2>&1 || rollback_failed=1
        systemctl --user daemon-reload >/dev/null 2>&1 || rollback_failed=1
        case $INSTALL_OLD_SOCKET_ENABLE_STATE in
            enabled) systemctl --user enable keepalive.socket >/dev/null 2>&1 || rollback_failed=1 ;;
            enabled-runtime) systemctl --user enable --runtime keepalive.socket >/dev/null 2>&1 || rollback_failed=1 ;;
        esac
        case $INSTALL_OLD_SERVICE_ENABLE_STATE in
            enabled) systemctl --user enable keepalive.service >/dev/null 2>&1 || rollback_failed=1 ;;
            enabled-runtime) systemctl --user enable --runtime keepalive.service >/dev/null 2>&1 || rollback_failed=1 ;;
        esac
        restore_managed_unit_links || rollback_failed=1
        if ((INSTALL_OLD_SOCKET_ACTIVE == 1)); then
            systemctl --user start keepalive.socket >/dev/null 2>&1 || rollback_failed=1
        fi
        if ((INSTALL_OLD_SERVICE_ACTIVE == 1)); then
            systemctl --user start keepalive.service >/dev/null 2>&1 || rollback_failed=1
        fi
        if ((rollback_failed == 1)); then
            printf 'install: ERROR: rollback was incomplete; inspect %s and %s before retrying\n' \
                "$INSTALL_BACKUP" "$INSTALL_UNIT_BACKUP" >&2
        fi
    fi
    [[ -z $INSTALL_STAGE ]] || rm -rf -- "$INSTALL_STAGE"
    if ((rollback_failed == 0)); then
        [[ -z $INSTALL_BACKUP ]] || rm -rf -- "$INSTALL_BACKUP"
        [[ -z $INSTALL_UNIT_BACKUP ]] || rm -rf -- "$INSTALL_UNIT_BACKUP"
    fi
    exit "$rc"
}

# Role: Install source, symlink, and user systemd units without requiring sudo.
main() {
    ((EUID != 0)) || die 'do not run this installer with sudo/root'
    [[ ${HOME:-} == /* ]] || die 'HOME must be an absolute path for a per-user installation'
    command -v systemctl >/dev/null 2>&1 || die 'systemctl is required for user-service installation'
    prepare_user_manager_environment
    local caller_runtime_dir=${XDG_RUNTIME_DIR:-}
    local manager_environment manager_config_home='' manager_effective_config_home
    local manager_home='' manager_runtime_dir='' name value
    if ! manager_environment=$(systemctl --user show-environment 2>/dev/null); then
        die 'the systemd user manager is unavailable; log in through a systemd user session and retry'
    fi
    while IFS='=' read -r name value; do
        case $name in
            HOME) manager_home=$value ;;
            XDG_CONFIG_HOME) manager_config_home=$value ;;
            XDG_RUNTIME_DIR) manager_runtime_dir=$value ;;
        esac
    done <<<"$manager_environment"
    local install_home
    canonical_path "$HOME" || die 'could not canonicalize HOME'
    install_home=$REPLY
    if [[ -n $manager_home ]]; then
        [[ $manager_home == /* ]] || die 'the systemd user manager has a relative HOME'
        canonical_path "$manager_home" || die 'could not canonicalize the systemd user manager HOME'
        [[ $REPLY == "$install_home" ]] \
            || die 'HOME differs from the systemd user manager; use the login user environment and retry'
    fi
    manager_home=${manager_home:-$install_home}
    canonical_path "$manager_home" || die 'could not canonicalize the effective user-manager HOME'
    manager_home=$REPLY

    local manager_effective_runtime=''
    if [[ -n $manager_runtime_dir ]]; then
        runtime_dir_is_safe "$manager_runtime_dir" \
            || die 'the systemd user manager has an unsafe XDG_RUNTIME_DIR'
        canonical_path "$manager_runtime_dir" || die 'could not canonicalize the systemd user manager runtime path'
        manager_effective_runtime=$REPLY
    elif runtime_dir_is_safe "/run/user/$UID"; then
        manager_effective_runtime="/run/user/$UID"
    fi
    if [[ -n $manager_effective_runtime ]]; then
        [[ -n $caller_runtime_dir ]] \
            || die 'the shell has no safe XDG_RUNTIME_DIR matching the systemd user manager'
        runtime_dir_is_safe "$caller_runtime_dir" \
            || die 'the shell has an unsafe XDG_RUNTIME_DIR'
        canonical_path "$caller_runtime_dir" || die 'could not canonicalize XDG_RUNTIME_DIR'
        [[ $REPLY == "$manager_effective_runtime" ]] \
            || die 'XDG_RUNTIME_DIR differs from the systemd user manager runtime directory'
    fi
    if [[ -n $manager_effective_runtime ]]; then
        export XDG_RUNTIME_DIR=$manager_effective_runtime
    fi

    [[ -z $manager_config_home || $manager_config_home == /* ]] \
        || die 'the systemd user manager has a relative XDG_CONFIG_HOME'
    manager_effective_config_home=${manager_config_home:-"$manager_home/.config"}
    canonical_path "$manager_effective_config_home" \
        || die 'could not canonicalize the systemd user manager configuration path'
    manager_effective_config_home=$REPLY

    local root root_canonical share share_canonical share_parent bin config_home caller_config_home units legacy_units unit
    local previous_unit_root='' persisted_unit_root=''
    local -a legacy_unit_roots=()
    root=$(project_root)
    canonical_path "$root" || die 'could not canonicalize the installer source tree'
    root_canonical=$REPLY
    share="$install_home/.local/share/keepalive-manager"
    canonical_path "$share" || die 'could not canonicalize the installation path'
    share_canonical=$REPLY
    share_parent=${share%/*}
    bin="$install_home/.local/bin"
    if [[ -n ${XDG_CONFIG_HOME:-} ]]; then
        canonical_path "$XDG_CONFIG_HOME" || die 'XDG_CONFIG_HOME must be an absolute path'
        caller_config_home=$REPLY
    else
        canonical_path "$install_home/.config" || die 'could not canonicalize the default configuration path'
        caller_config_home=$REPLY
    fi
    if [[ $caller_config_home != "$manager_effective_config_home" ]]; then
        die 'the shell and systemd user manager resolve different XDG_CONFIG_HOME paths; configure the login session and retry'
    fi
    config_home=$manager_effective_config_home
    canonical_path "$config_home/systemd/user" || die 'could not canonicalize the systemd user unit path'
    units=$REPLY
    canonical_path "$install_home/.config/systemd/user" || die 'could not canonicalize the default systemd user unit path'
    legacy_units=$REPLY
    paths_overlap "$config_home" "$share_canonical" \
        && die 'XDG_CONFIG_HOME and the installed source tree must not overlap'
    paths_overlap "$units" "$share_canonical" \
        && die 'the systemd user unit path and installed source tree must not overlap'
    paths_overlap "$config_home" "$root_canonical" \
        && die 'XDG_CONFIG_HOME and the installer source tree must not overlap'
    paths_overlap "$units" "$root_canonical" \
        && die 'the systemd user unit path and installer source tree must not overlap'
    if [[ -e $share || -L $share ]]; then
        [[ ! -L $share && -d $share ]] \
            || die "$share exists but is not a normal directory"
        installed_share_is_managed "$share" \
            || die "$share exists but is not a recognized Keep Alive Manager installation; preserving it"
    fi
    if [[ -f $share/.installed-unit-root && ! -L $share/.installed-unit-root \
        && -r $share/.installed-unit-root ]]; then
        IFS= read -r persisted_unit_root <"$share/.installed-unit-root" || true
        if [[ $persisted_unit_root == /*/systemd/user ]]; then
            canonical_path "$persisted_unit_root" && previous_unit_root=$REPLY
        fi
    fi
    legacy_unit_roots+=("$legacy_units")
    [[ -z $previous_unit_root ]] || legacy_unit_roots+=("$previous_unit_root")
    INSTALL_SHARE=$share
    INSTALL_UNITS=$units
    INSTALL_LINK="$bin/keepalive"

    mkdir -p "$share_parent" "$bin" "$units"
    canonical_path "$units" || die 'could not canonicalize the created systemd user unit path'
    units=$REPLY
    INSTALL_UNITS=$units
    paths_overlap "$units" "$share_canonical" \
        && die 'the systemd user unit path and installed source tree overlap after creation'
    paths_overlap "$units" "$root_canonical" \
        && die 'the systemd user unit path and installer source tree overlap after creation'
    [[ ! -e $INSTALL_LINK || -L $INSTALL_LINK ]] \
        || die "$INSTALL_LINK exists and is not a symlink"
    if [[ -L $INSTALL_LINK ]]; then
        INSTALL_HAD_LINK=1
        INSTALL_OLD_LINK_TARGET=$(readlink -- "$INSTALL_LINK")
    fi

    # Build the entire source payload before touching the currently usable install.
    INSTALL_STAGE=$(mktemp -d "$share_parent/.keepalive-manager.install.XXXXXX")
    cp -a -- "$root/lib" "$root/systemd" "$root/docs" "$root/tests" "$root/scripts" "$INSTALL_STAGE/"
    cp -f -- "$root/keepalive" "$root/README.md" "$INSTALL_STAGE/"
    chmod +x "$INSTALL_STAGE/keepalive" "$INSTALL_STAGE/scripts/"*.sh "$INSTALL_STAGE/tests/"*.sh
    printf '%s\n' "$units" >"$INSTALL_STAGE/.installed-unit-root"
    chmod 0600 "$INSTALL_STAGE/.installed-unit-root"

    INSTALL_UNIT_BACKUP=$(mktemp -d "$share_parent/.keepalive-manager.units.XXXXXX")
    for unit in keepalive.service keepalive.socket; do
        if [[ -e $units/$unit && ! -f $units/$unit && ! -L $units/$unit ]]; then
            die "$units/$unit exists but is not a regular file or symlink"
        fi
        if [[ -e $units/$unit || -L $units/$unit ]]; then
            cp -a -- "$units/$unit" "$INSTALL_UNIT_BACKUP/$unit"
        fi
    done
    snapshot_managed_unit_links "$units" \
        || die 'a reserved systemd enablement-link path is unsafe or could not be backed up'
    INSTALL_BACKUP=$(mktemp -d "$share_parent/.keepalive-manager.previous.XXXXXX")
    [[ -e $share ]] && INSTALL_HAD_SHARE=1

    # Capture this before replacing units. Disabling without --now removes obsolete
    # install links but intentionally keeps a running daemon alive until the update is
    # complete and can restart it onto the new code.
    unit_active_state keepalive.service \
        || die 'could not determine whether keepalive.service is active'
    [[ $REPLY == active ]] && INSTALL_OLD_SERVICE_ACTIVE=1
    unit_enable_state keepalive.socket \
        || die 'could not determine whether keepalive.socket is enabled'
    INSTALL_OLD_SOCKET_ENABLE_STATE=$REPLY
    unit_active_state keepalive.socket \
        || die 'could not determine whether keepalive.socket is active'
    [[ $REPLY == active ]] && INSTALL_OLD_SOCKET_ACTIVE=1
    unit_enable_state keepalive.service \
        || die 'could not determine whether keepalive.service is enabled'
    INSTALL_OLD_SERVICE_ENABLE_STATE=$REPLY

    # Record which keep-alives are running before anything changes, so the restart can
    # be checked to have reloaded every one of them onto the new code.
    # Best-effort throughout: this is a report, and it must never abort an installation.
    local runtime manifest='' old_daemon_pid=''
    install_runtime_dir; runtime=$REPLY
    manifest=$(install_target_manifest "$runtime" 2>/dev/null) || manifest=''
    install_running_daemon_pid "$runtime" && old_daemon_pid=$REPLY
    INSTALL_ROLLBACK_ARMED=1
    systemctl --user disable keepalive.socket keepalive.service >/dev/null 2>&1 || true
    remove_managed_unit_links "$units"

    if ((INSTALL_HAD_SHARE == 1)); then
        INSTALL_BACKUP_CREATED=1
        mv -T -- "$share" "$INSTALL_BACKUP/tree"
    fi
    INSTALL_NEW_SHARE_LIVE=1
    mv -T -- "$INSTALL_STAGE" "$share"
    INSTALL_STAGE=''
    ln -sfn "$share/keepalive" "$bin/keepalive"
    # Read units from the staged tree now living at $share. This also supports running
    # the installer from an existing installation whose old tree was just backed up.
    install_unit_file "$share/systemd/keepalive.service" "$units/keepalive.service"
    install_unit_file "$share/systemd/keepalive.socket" "$units/keepalive.socket"

    systemctl --user daemon-reload
    systemctl --user enable --now keepalive.socket

    # A running daemon has already sourced the previous modules and keeps executing them
    # until restarted, so an update would otherwise leave new clients talking to old code.
    # The stop is graceful: the daemon finishes any delivery in flight, flushes every
    # countdown, and the new instance reloads the targets from those checkpoints.
    if ((INSTALL_OLD_SERVICE_ACTIVE == 1)); then
        printf 'Restarting the running daemon to load the updated code.\n'
        systemctl --user restart keepalive.service
    fi

    INSTALL_ROLLBACK_ARMED=0

    # The new code is live from here on: nothing below may fail the installation, so
    # every report is run where errexit does not apply and its status is ignored.
    if ((INSTALL_OLD_SERVICE_ACTIVE == 1)) && [[ -n $old_daemon_pid ]]; then
        if install_wait_for_new_daemon "$runtime" "$old_daemon_pid"; then
            if [[ -n $manifest ]]; then
                install_report_reload "$runtime" "$manifest" || true
            fi
        else
            printf 'install: warning: the restarted daemon has not reported itself online after 60 s; its keep-alives reload when it does. Check: systemctl --user status keepalive.service\n' >&2
        fi
    elif [[ -n $old_daemon_pid ]]; then
        # Running, but not as the systemd unit: nothing here may restart it, and while it
        # holds the runtime lock a socket-started instance exits at once.
        printf 'install: warning: a Keep Alive daemon not started by systemd (pid %s) is still running the previous code.\n' \
            "$old_daemon_pid" >&2
        printf 'install: warning: stop it with: kill %s  (it saves every countdown on the way out); the socket then starts the updated daemon.\n' \
            "$old_daemon_pid" >&2
    elif [[ -n $manifest ]]; then
        printf 'Keep-alives are configured but no daemon is running; any keepalive command starts the updated one and resumes them.\n'
    fi

    # A manager using custom XDG_CONFIG_HOME does not search the old default tree. Remove
    # files created there by legacy releases only after the new installation is live. A
    # cleanup failure does not invalidate that live installation.
    local old_root
    local -A cleaned_roots=()
    for old_root in "${legacy_unit_roots[@]}"; do
        [[ $old_root != "$units" && -z ${cleaned_roots[$old_root]+x} ]] || continue
        cleaned_roots["$old_root"]=1
        if ! remove_managed_unit_links "$old_root" \
            || ! rm -f -- "$old_root/keepalive.socket" "$old_root/keepalive.service"; then
            printf 'install: warning: could not remove every legacy unit file under %s\n' \
                "$old_root" >&2
        fi
    done

    printf 'Installed Keep Alive Manager.\n'
    printf 'Command: %s/keepalive\n' "$bin"
    printf 'Try: keepalive doctor\n'
}

trap finish_install EXIT
main "$@"
