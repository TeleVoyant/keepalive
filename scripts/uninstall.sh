#!/usr/bin/env bash
# Remove the current user's Keep Alive installation without touching AI/Konsole processes.
set -Eeuo pipefail

UNINSTALL_MANAGED_PATHS=(
    keepalive.socket
    keepalive.service
    sockets.target.wants/keepalive.socket
    sockets.target.wants/keepalive.service
    graphical-session.target.wants/keepalive.socket
    graphical-session.target.wants/keepalive.service
)
UNINSTALL_ENABLEMENT_LINKS=(
    sockets.target.wants/keepalive.socket
    sockets.target.wants/keepalive.service
    graphical-session.target.wants/keepalive.socket
    graphical-session.target.wants/keepalive.service
)
UNINSTALL_LINK_BACKUP=''
declare -a UNINSTALL_SNAPSHOT_ROOTS=()
declare -A UNINSTALL_SNAPSHOT_BY_ROOT=()

# Role: Remove only the private temporary enablement snapshot created by this process.
cleanup_uninstall_snapshot() {
    [[ -n $UNINSTALL_LINK_BACKUP ]] || return 0
    rm -rf -- "$UNINSTALL_LINK_BACKUP" 2>/dev/null || true
    UNINSTALL_LINK_BACKUP=''
}

# Role: Canonicalize an absolute path through all existing symlink components.
canonical_path() {
    local path=$1 canonical
    [[ $path == /* ]] || return 1
    canonical=$(readlink -f -- "$path" 2>/dev/null) \
        || canonical=$(readlink -m -- "$path") \
        || return 1
    [[ $canonical == /* ]] || return 1
    REPLY=$canonical
}

# Role: Accept group write only for the current user's private primary group.
directory_group_is_private() {
    local gid=$1 user_name primary_gid group_record group_name group_gid group_members passwd_records
    local passwd_name passwd_password passwd_uid passwd_gid passwd_gecos passwd_home passwd_shell
    user_name=$(id -un) || return 1
    primary_gid=$(id -g) || return 1
    [[ $gid == "$primary_gid" ]] || return 1
    group_record=$(getent group "$gid") || return 1
    IFS=: read -r group_name _ group_gid group_members <<<"$group_record"
    [[ $group_name == "$user_name" && $group_gid == "$gid" && -z $group_members ]] || return 1
    passwd_records=$(getent passwd) || return 1
    while IFS=: read -r passwd_name passwd_password passwd_uid passwd_gid passwd_gecos passwd_home passwd_shell; do
        [[ $passwd_gid == "$gid" && $passwd_name != "$user_name" ]] && return 1
    done <<<"$passwd_records"
    return 0
}

# Role: Validate canonical directory components and the permitted private-group policy.
# Symlinked configured roots are canonicalized before this call; a symlink seen here is
# therefore a newly planted component below a trusted root and is rejected.
directory_components_are_safe() {
    local path=${1:-} allow_sticky_final=${2:-0} normalized current component mode mode_bits owner group remaining sticky_exception
    [[ $path == /* ]] || return 1
    normalized=$path
    while [[ $normalized != / && $normalized == */ ]]; do normalized=${normalized%/}; done
    remaining=${normalized#/}
    current=/
    while [[ -n $remaining ]]; do
        component=${remaining%%/*}
        if [[ $remaining == */* ]]; then remaining=${remaining#*/}; else remaining=''; fi
        [[ -n $component && $component != . && $component != .. ]] || return 1
        if [[ $current == / ]]; then current="/$component"; else current="$current/$component"; fi
        [[ -L $current ]] && return 1
        [[ -e $current ]] || break
        [[ -d $current ]] || return 1
        owner=$(stat -Lc '%u' -- "$current") || return 1
        [[ $owner == "$EUID" || $owner == 0 ]] || return 1
        mode=$(stat -Lc '%a' -- "$current") || return 1
        group=$(stat -Lc '%g' -- "$current") || return 1
        [[ $mode =~ ^[0-7]{3,4}$ ]] || return 1
        mode_bits=$((8#$mode))
        sticky_exception=0
        if (( owner == 0 && (mode_bits & 01000) != 0 )) \
            && [[ $current != "$normalized" || $allow_sticky_final == 1 ]]; then
            sticky_exception=1
        fi
        (( (mode_bits & 0002) == 0 || sticky_exception == 1 )) || return 1
        if (( (mode_bits & 0020) != 0 && sticky_exception == 0 )) \
            && ! directory_group_is_private "$group"; then
            return 1
        fi
        if [[ $current == "$normalized" && $owner != "$EUID" && $allow_sticky_final != 1 ]]; then return 1; fi
    done
}

# Role: Validate one managed unit entry and every parent before removing it.
unit_entry_is_safe() {
    local path=$1 parent
    parent=${path%/*}
    [[ $parent != "$path" ]] || parent=/
    directory_components_are_safe "$parent" || return 1
    [[ ! -d $path || -L $path ]] || return 1
    if [[ -L $path ]]; then
        [[ $(stat -c '%u' -- "$path") == "$EUID" ]] || return 1
    elif [[ -e $path ]]; then
        [[ -f $path && -O $path ]] || return 1
    fi
}

# Role: Validate the exact runtime tree before an opt-in purge can remove it.
runtime_tree_is_safe() {
    local runtime=$1 entry mode mode_bits group
    [[ -e $runtime || -L $runtime ]] || return 0
    runtime_dir_is_safe "${runtime%/}" || return 1
    [[ -d $runtime && ! -L $runtime ]] || return 1
    directory_components_are_safe "$runtime" || return 1
    find -P "$runtime" -xdev -print0 2>/dev/null |
        while IFS= read -r -d '' entry; do
            [[ ! -L $entry ]] || return 1
            [[ -O $entry ]] || return 1
            if [[ -d $entry ]]; then
                mode=$(stat -Lc '%a' -- "$entry") || return 1
                group=$(stat -Lc '%g' -- "$entry") || return 1
                [[ $mode =~ ^[0-7]{3,4}$ ]] || return 1
                mode_bits=$((8#$mode))
                (( (mode_bits & 0002) == 0 )) || return 1
                if (( (mode_bits & 0020) != 0 )) && ! directory_group_is_private "$group"; then
                    return 1
                fi
            fi
        done
}

# Role: Accept only an absolute, owned runtime path with private permissions and no symlinks.
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

# Role: Recover the standard systemd user-runtime path when the shell omitted or corrupted it.
prepare_user_manager_environment() {
    if [[ -n ${XDG_RUNTIME_DIR:-} ]] && ! runtime_dir_is_safe "$XDG_RUNTIME_DIR"; then
        unset XDG_RUNTIME_DIR
    fi
    if [[ -z ${XDG_RUNTIME_DIR:-} ]] && runtime_dir_is_safe "/run/user/$UID"; then
        export XDG_RUNTIME_DIR="/run/user/$UID"
    fi
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

# Role: Reject directory-shaped reserved paths before an uninstall removes any files.
validate_units_root() {
    local unit_root=$1 relative path
    directory_components_are_safe "$unit_root" || return 1
    for relative in "${UNINSTALL_MANAGED_PATHS[@]}"; do
        path="$unit_root/$relative"
        unit_entry_is_safe "$path" || return 1
    done
}

# Role: Remove shipped unit files and install links while retaining user-owned drop-ins.
remove_units_from_root() {
    local unit_root=$1 relative path
    validate_units_root "$unit_root" || return 1
    for relative in "${UNINSTALL_MANAGED_PATHS[@]}"; do
        path="$unit_root/$relative"
        unit_entry_is_safe "$path" || return 1
        rm -f -- "$path" || return 1
    done
}

# Role: Snapshot exact persistent enablement entries before systemctl may remove them.
snapshot_enablement_links() {
    local unit_root=$1 backup=$2 relative source destination
    validate_units_root "$unit_root" || return 1
    mkdir -p -- "$backup" || return 1
    for relative in "${UNINSTALL_ENABLEMENT_LINKS[@]}"; do
        source="$unit_root/$relative"
        unit_entry_is_safe "$source" || return 1
        [[ -e $source || -L $source ]] || continue
        destination="$backup/$relative"
        mkdir -p -- "${destination%/*}" || return 1
        cp -a -- "$source" "$destination" || return 1
    done
}

# Role: Compare regular-file bytes without requiring diffutils' cmp utility.
uninstall_files_equal() {
    local left=$1 right=$2 left_hash right_hash
    left_hash=$(sha256sum -- "$left") || return 1
    right_hash=$(sha256sum -- "$right") || return 1
    [[ ${left_hash%% *} == "${right_hash%% *}" ]]
}

# Role: Report whether an enablement entry still exactly matches its saved form.
enablement_entry_matches() {
    local current=$1 saved=$2 current_target saved_target
    if [[ -L $saved ]]; then
        [[ -L $current ]] || return 1
        current_target=$(readlink -- "$current") || return 1
        saved_target=$(readlink -- "$saved") || return 1
        [[ $current_target == "$saved_target" ]]
    elif [[ -f $saved && ! -L $saved ]]; then
        [[ -f $current && ! -L $current ]] && uninstall_files_equal "$saved" "$current"
    else
        return 1
    fi
}

# Role: Restore every snapshotted enablement entry without overwriting a concurrent replacement.
restore_enablement_links() {
    local root backup relative saved destination
    for root in "${UNINSTALL_SNAPSHOT_ROOTS[@]}"; do
        backup=${UNINSTALL_SNAPSHOT_BY_ROOT[$root]}
        for relative in "${UNINSTALL_ENABLEMENT_LINKS[@]}"; do
            saved="$backup/$relative"
            [[ -e $saved || -L $saved ]] || continue
            destination="$root/$relative"
            unit_entry_is_safe "$destination" || return 1
            if [[ -e $destination || -L $destination ]]; then
                enablement_entry_matches "$destination" "$saved" || return 1
                continue
            fi
            mkdir -p -- "${destination%/*}" || return 1
            cp -a -- "$saved" "$destination" || return 1
        done
    done
}

# Role: Remove only the command symlink installed by this project, preserving replacements.
remove_installed_command_link() {
    local path=$1 expected=$2 target resolved expected_resolved
    directory_components_are_safe "${path%/*}" || return 1
    [[ -e $path || -L $path ]] || return 0
    if [[ ! -L $path ]]; then
        printf 'uninstall: warning: preserving non-symlink command replacement at %s\n' "$path" >&2
        return 0
    fi
    target=$(readlink -- "$path") || return 1
    [[ $target == /* ]] || target="${path%/*}/$target"
    canonical_path "$target" || return 1
    resolved=$REPLY
    canonical_path "$expected" || return 1
    expected_resolved=$REPLY
    if [[ $resolved != "$expected_resolved" ]]; then
        printf 'uninstall: warning: preserving command symlink with a different target at %s\n' "$path" >&2
        return 0
    fi
    rm -f -- "$path"
}

# Role: Recognize the installed application tree before allowing recursive removal.
installed_share_is_managed() {
    local share=$1
    [[ -d $share && ! -L $share \
        && -f $share/keepalive && ! -L $share/keepalive \
        && -f $share/scripts/uninstall.sh && ! -L $share/scripts/uninstall.sh \
        && -f $share/systemd/keepalive.service && ! -L $share/systemd/keepalive.service \
        && -f $share/systemd/keepalive.socket && ! -L $share/systemd/keepalive.socket ]]
}

# Role: Return a persisted unit root only when its installation-time inode record still matches.
read_validated_persisted_unit_root() {
    local share=$1 persisted normalized recorded_fingerprint current_fingerprint
    local recorded_device recorded_inode recorded_owner recorded_mode
    REPLY=''
    installed_share_is_managed "$share" || return 1
    [[ -f $share/.installed-unit-root && ! -L $share/.installed-unit-root \
        && -r $share/.installed-unit-root && -O $share/.installed-unit-root ]] || return 1
    [[ -f $share/.installed-unit-root.validation && ! -L $share/.installed-unit-root.validation \
        && -r $share/.installed-unit-root.validation && -O $share/.installed-unit-root.validation ]] || return 1
    IFS= read -r persisted <"$share/.installed-unit-root" || return 1
    IFS= read -r recorded_fingerprint <"$share/.installed-unit-root.validation" || return 1
    [[ $persisted == /*/systemd/user ]] || return 1
    canonical_path "$persisted" || return 1
    normalized=$REPLY
    [[ $normalized == "$persisted" ]] || return 1
    directory_components_are_safe "$normalized" || return 1
    IFS=: read -r recorded_device recorded_inode recorded_owner recorded_mode <<<"$recorded_fingerprint"
    recorded_fingerprint="$recorded_device:$recorded_inode:$recorded_owner"
    current_fingerprint=$(stat -Lc '%d:%i:%u' -- "$normalized") || return 1
    [[ $recorded_fingerprint == "$current_fingerprint" ]] || return 1
    REPLY=$normalized
}

# Role: Validate the exact runtime location selected for an opt-in purge.
runtime_purge_is_safe() {
    local runtime_base runtime
    runtime_base=${XDG_RUNTIME_DIR:-"/run/user/$UID"}
    runtime_dir_is_safe "$runtime_base" || return 1
    runtime="$runtime_base/keepalive"
    runtime_tree_is_safe "$runtime"
}

# Role: Remove the exact private runtime tree after systemd confirmed both units stopped.
purge_runtime_tree() {
    local runtime_base runtime
    runtime_purge_is_safe || {
        printf 'uninstall: ERROR: refusing runtime purge because the selected path is not an exact owned private tree\n' >&2
        return 1
    }
    runtime_base=${XDG_RUNTIME_DIR:-"/run/user/$UID"}
    runtime="$runtime_base/keepalive"
    runtime_tree_is_safe "$runtime" || {
        printf 'uninstall: ERROR: refusing runtime purge because %s is not an exact owned private tree\n' \
            "$runtime" >&2
        return 1
    }
    [[ -e $runtime || -L $runtime ]] || return 0
    rm -rf -- "$runtime"
}

# Role: Remove installed user units, binary link, and application source tree.
main() {
    ((EUID != 0)) || { printf 'uninstall: do not run as root\n' >&2; exit 1; }
    [[ ${HOME:-} == /* ]] || { printf 'uninstall: HOME must be an absolute path\n' >&2; exit 1; }
    local force=0 purge_runtime=0 option
    while (($#)); do
        case $1 in
            --force) force=1 ;;
            --purge-runtime) purge_runtime=1 ;;
            *) printf 'usage: %s [--force] [--purge-runtime]\n' "${0##*/}" >&2; exit 2 ;;
        esac
        shift
    done

    prepare_user_manager_environment
    local caller_runtime_dir=${XDG_RUNTIME_DIR:-}
    local config_home manager_config_home='' manager_environment='' manager_home=''
    local manager_runtime_dir='' manager_effective_runtime=''
    local name value root manager_available=0 stop_confirmed=0 disable_rc=0
    local install_home share share_input bin command_link
    local -a unit_roots=()
    canonical_path "$HOME" \
        || { printf 'uninstall: could not canonicalize HOME\n' >&2; exit 1; }
    install_home=$REPLY
    directory_components_are_safe "$install_home" \
        || { printf 'uninstall: HOME resolves to an unsafe directory\n' >&2; exit 1; }
    share_input="$install_home/.local/share/keepalive-manager"
    [[ ! -L $share_input ]] \
        || { printf 'uninstall: refusing symlinked installation tree %s\n' "$share_input" >&2; exit 1; }
    canonical_path "$share_input" \
        || { printf 'uninstall: could not canonicalize the installation path\n' >&2; exit 1; }
    share=$REPLY
    canonical_path "$install_home/.local/share" \
        || { printf 'uninstall: could not canonicalize the installation parent\n' >&2; exit 1; }
    directory_components_are_safe "$REPLY" \
        || { printf 'uninstall: installation parent has unsafe ownership or permissions\n' >&2; exit 1; }
    canonical_path "$install_home/.local/bin" \
        || { printf 'uninstall: could not canonicalize the command directory\n' >&2; exit 1; }
    bin=$REPLY
    directory_components_are_safe "$bin" \
        || { printf 'uninstall: command directory has unsafe ownership or permissions\n' >&2; exit 1; }
    command_link="$bin/keepalive"

    if command -v systemctl >/dev/null 2>&1; then
        if manager_environment=$(systemctl --user show-environment 2>/dev/null); then
            manager_available=1
        fi
        while IFS='=' read -r name value; do
            case $name in
                HOME) manager_home=$value ;;
                XDG_CONFIG_HOME) manager_config_home=$value ;;
                XDG_RUNTIME_DIR) manager_runtime_dir=$value ;;
            esac
        done <<<"$manager_environment"
    fi
    if ((manager_available == 0 && force == 0)); then
        printf 'uninstall: ERROR: the systemd user manager is unavailable; no files were removed\n' >&2
        printf 'uninstall: retry from a systemd user session, or use --force only after confirming no daemon is running\n' >&2
        exit 1
    fi
    if [[ -n $manager_home ]]; then
        canonical_path "$manager_home" \
            || { printf 'uninstall: the systemd user manager has an invalid HOME\n' >&2; exit 1; }
        manager_home=$REPLY
        if [[ $manager_home != "$install_home" ]]; then
            printf 'uninstall: ERROR: HOME differs from the systemd user manager; no files were removed\n' >&2
            exit 1
        fi
    else
        manager_home=$install_home
    fi

    if ((manager_available == 1)); then
        if [[ -n $manager_runtime_dir ]]; then
            runtime_dir_is_safe "$manager_runtime_dir" \
                || { printf 'uninstall: the systemd user manager has an unsafe XDG_RUNTIME_DIR\n' >&2; exit 1; }
            canonical_path "$manager_runtime_dir" || exit 1
            manager_effective_runtime=$REPLY
        elif runtime_dir_is_safe "/run/user/$UID"; then
            manager_effective_runtime="/run/user/$UID"
        fi
        if [[ -n $manager_effective_runtime ]]; then
            [[ -n $caller_runtime_dir ]] || {
                printf 'uninstall: ERROR: the shell has no safe XDG_RUNTIME_DIR matching the systemd user manager\n' >&2
                exit 1
            }
            runtime_dir_is_safe "$caller_runtime_dir" || {
                printf 'uninstall: ERROR: the shell has an unsafe XDG_RUNTIME_DIR\n' >&2
                exit 1
            }
            canonical_path "$caller_runtime_dir" || exit 1
            if [[ $REPLY != "$manager_effective_runtime" ]]; then
                printf 'uninstall: ERROR: XDG_RUNTIME_DIR differs from the systemd user manager; no files were removed\n' >&2
                exit 1
            fi
        fi
        [[ -z $manager_effective_runtime ]] || export XDG_RUNTIME_DIR=$manager_effective_runtime
    fi

    config_home=${manager_config_home:-"$manager_home/.config"}
    canonical_path "$config_home" \
        || { printf 'uninstall: manager XDG_CONFIG_HOME must be absolute\n' >&2; exit 1; }
    config_home=$REPLY
    directory_components_are_safe "$config_home" \
        || { printf 'uninstall: manager XDG_CONFIG_HOME has unsafe ownership or permissions\n' >&2; exit 1; }

    local caller_config_home=${XDG_CONFIG_HOME:-"$install_home/.config"}
    canonical_path "$caller_config_home" \
        || { printf 'uninstall: XDG_CONFIG_HOME must be absolute\n' >&2; exit 1; }
    caller_config_home=$REPLY
    directory_components_are_safe "$caller_config_home" \
        || { printf 'uninstall: XDG_CONFIG_HOME has unsafe ownership or permissions\n' >&2; exit 1; }

    local candidate
    for candidate in "$config_home/systemd/user" "$caller_config_home/systemd/user" \
        "$install_home/.config/systemd/user"; do
        canonical_path "$candidate" || continue
        candidate=$REPLY
        directory_components_are_safe "$candidate" || continue
        unit_roots+=("$candidate")
    done
    if installed_share_is_managed "$share"; then
        directory_components_are_safe "$share" || {
            printf 'uninstall: ERROR: installed source tree has unsafe ownership or permissions\n' >&2
            exit 1
        }
        if read_validated_persisted_unit_root "$share"; then
            unit_roots+=("$REPLY")
        fi
    fi

    # Validate every root before systemctl disable can remove even the first enablement
    # link. A directory at a reserved unit path must never cause a partial uninstall.
    local -A validated=()
    for root in "${unit_roots[@]}"; do
        [[ -n ${validated[$root]+x} ]] && continue
        validated["$root"]=1
        validate_units_root "$root" || {
            printf 'uninstall: ERROR: reserved unit path is a directory under %s; no files were removed\n' "$root" >&2
            exit 1
        }
    done

    if ((manager_available == 1)); then
        local snapshot_base snapshot_index=0
        snapshot_base=${manager_effective_runtime:-/tmp}
        UNINSTALL_LINK_BACKUP=$(mktemp -d "$snapshot_base/keepalive-uninstall.XXXXXX") || {
            printf 'uninstall: ERROR: could not create enablement rollback state; no files were removed\n' >&2
            exit 1
        }
        chmod 700 "$UNINSTALL_LINK_BACKUP" || {
            printf 'uninstall: ERROR: could not secure enablement rollback state; no files were removed\n' >&2
            exit 1
        }
        for root in "${unit_roots[@]}"; do
            [[ -z ${UNINSTALL_SNAPSHOT_BY_ROOT[$root]+x} ]] || continue
            snapshot_index=$((snapshot_index + 1))
            UNINSTALL_SNAPSHOT_ROOTS+=("$root")
            UNINSTALL_SNAPSHOT_BY_ROOT["$root"]="$UNINSTALL_LINK_BACKUP/$snapshot_index"
            snapshot_enablement_links "$root" "${UNINSTALL_SNAPSHOT_BY_ROOT[$root]}" || {
                printf 'uninstall: ERROR: could not snapshot systemd enablement links; no files were removed\n' >&2
                exit 1
            }
        done
    fi

    if ((manager_available == 1)); then
        systemctl --user disable --now keepalive.socket keepalive.service >/dev/null 2>&1 || disable_rc=$?
        if systemctl --user show-environment >/dev/null 2>&1; then
            local service_state='' socket_state='' status_rc=0
            if unit_active_state keepalive.service; then
                service_state=$REPLY
            else
                status_rc=$?
                printf 'uninstall: ERROR: could not determine whether keepalive.service is active; no files were removed\n' >&2
                if ! restore_enablement_links; then
                    printf 'uninstall: ERROR: restoring persistent enablement links also failed\n' >&2
                    exit 1
                fi
                exit "$status_rc"
            fi
            if unit_active_state keepalive.socket; then
                socket_state=$REPLY
            else
                status_rc=$?
                printf 'uninstall: ERROR: could not determine whether keepalive.socket is active; no files were removed\n' >&2
                if ! restore_enablement_links; then
                    printf 'uninstall: ERROR: restoring persistent enablement links also failed\n' >&2
                    exit 1
                fi
                exit "$status_rc"
            fi
            if [[ $service_state == inactive && $socket_state == inactive ]]; then
                stop_confirmed=1
            fi
        else
            status_rc=$?
            printf 'uninstall: ERROR: the systemd user manager became unavailable while confirming shutdown; no files were removed\n' >&2
            if ! restore_enablement_links; then
                printf 'uninstall: ERROR: restoring persistent enablement links also failed\n' >&2
                exit 1
            fi
            exit "$status_rc"
        fi
    fi
    if ((stop_confirmed == 0 && force == 0)); then
        printf 'uninstall: ERROR: could not confirm that all user units stopped; no files were removed\n' >&2
        printf 'uninstall: resolve the user-manager problem, or use --force only after checking the daemon manually\n' >&2
        if ((manager_available == 1)) && ! restore_enablement_links; then
            printf 'uninstall: ERROR: restoring persistent enablement links also failed\n' >&2
            exit 1
        fi
        exit 1
    fi
    if ((stop_confirmed == 0)); then
        printf 'uninstall: warning: forcing file removal without a confirmed daemon stop\n' >&2
    elif ((disable_rc != 0)); then
        printf 'uninstall: warning: unit disablement reported status %d, but both units are confirmed inactive\n' \
            "$disable_rc" >&2
    fi

    if ((purge_runtime == 1)); then
        if ((stop_confirmed == 0)); then
            printf 'uninstall: ERROR: --purge-runtime requires a confirmed stopped daemon; no files were removed\n' >&2
            if ((manager_available == 1)) && ! restore_enablement_links; then
                printf 'uninstall: ERROR: restoring persistent enablement links also failed\n' >&2
            fi
            exit 1
        fi
        if ! runtime_purge_is_safe; then
            printf 'uninstall: ERROR: --purge-runtime found an unsafe or foreign runtime tree; no files were removed\n' >&2
            if ((manager_available == 1)) && ! restore_enablement_links; then
                printf 'uninstall: ERROR: restoring persistent enablement links also failed\n' >&2
            fi
            exit 1
        fi
    fi

    local cleanup_rc=0 operation_rc=0 reload_rc=0
    local -A seen=()
    for root in "${unit_roots[@]}"; do
        [[ -n ${seen[$root]+x} ]] && continue
        seen["$root"]=1
        remove_units_from_root "$root" || {
            operation_rc=$?
            ((cleanup_rc != 0)) || cleanup_rc=$operation_rc
        }
    done
    if ((cleanup_rc == 0)); then
        if installed_share_is_managed "$share"; then
            remove_installed_command_link "$command_link" "$share/keepalive" \
                || cleanup_rc=$?
            if ((cleanup_rc == 0)); then
                rm -rf -- "$share" || cleanup_rc=$?
            fi
        elif [[ -e $share || -L $share ]]; then
            printf 'uninstall: warning: preserving unrecognized directory at %s\n' "$share" >&2
        else
            # Complete an interrupted/idempotent uninstall by removing only the exact
            # dangling command link this installation would have created.
            remove_installed_command_link "$command_link" "$share/keepalive" \
                || cleanup_rc=$?
        fi
    fi
    if ((manager_available == 1)); then
        systemctl --user daemon-reload >/dev/null 2>&1 || reload_rc=$?
    fi
    if ((cleanup_rc != 0)); then
        printf 'uninstall: ERROR: file cleanup failed (status %d); the installed source tree was preserved when possible\n' \
            "$cleanup_rc" >&2
        ((reload_rc == 0)) \
            || printf 'uninstall: ERROR: user-manager daemon-reload also failed (status %d)\n' "$reload_rc" >&2
        return "$cleanup_rc"
    fi
    if ((reload_rc != 0)); then
        printf 'uninstall: ERROR: user-manager daemon-reload failed (status %d)\n' "$reload_rc" >&2
        return "$reload_rc"
    fi
    if ((purge_runtime == 1)); then
        if ((stop_confirmed == 0)); then
            printf 'uninstall: ERROR: --purge-runtime requires a confirmed stopped daemon; no runtime state was removed\n' >&2
            return 1
        fi
        purge_runtime_tree || return $?
        printf 'Runtime state purged from %s/keepalive.\n' "${XDG_RUNTIME_DIR:-/run/user/$UID}"
    fi
    printf 'Keep Alive Manager removed. Persistent profile left at %s\n' "$config_home/keepalive"
}

trap cleanup_uninstall_snapshot EXIT
main "$@"
