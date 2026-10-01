#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup

if ((EUID == 0)) && { ! command -v runuser >/dev/null 2>&1 || ! id nobody >/dev/null 2>&1; }; then
    test_skip 'install safety scenarios' 'no usable unprivileged account runner'
    test_finish
    exit
fi

fakebin="$TEST_TMP/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -u
state_dir=${FAKE_SYSTEMD_STATE_DIR:?}
mkdir -p "$state_dir"
printf '%s\n' "$*" >>"$state_dir/calls"
[[ ${1-} == --user ]] && shift
command=${1-}
[[ -z $command ]] || shift
manager_config=${FAKE_MANAGER_CONFIG_HOME:-${XDG_CONFIG_HOME:-$HOME/.config}}
unit_root=$(readlink -m -- "$manager_config")/systemd/user

case $command in
    show-environment)
        count=0
        [[ -r $state_dir/show-environment-count ]] && count=$(<"$state_dir/show-environment-count")
        count=$((count + 1))
        printf '%s\n' "$count" >"$state_dir/show-environment-count"
        if [[ -n ${FAKE_SHOW_ENV_FAIL_ON_CALL:-} && $count == "$FAKE_SHOW_ENV_FAIL_ON_CALL" ]]; then
            exit "${FAKE_SHOW_ENV_FAIL_RC:-73}"
        fi
        printf 'HOME=%s\n' "$HOME"
        if [[ -n ${FAKE_MANAGER_CONFIG_HOME:-} ]]; then
            printf 'XDG_CONFIG_HOME=%s\n' "$FAKE_MANAGER_CONFIG_HOME"
        fi
        if [[ -n ${FAKE_MANAGER_RUNTIME_DIR:-} ]]; then
            printf 'XDG_RUNTIME_DIR=%s\n' "$FAKE_MANAGER_RUNTIME_DIR"
        else
            printf 'XDG_RUNTIME_DIR=%s\n' "${XDG_RUNTIME_DIR-}"
        fi
        ;;
    is-active)
        [[ ${1-} == --quiet ]] && shift
        unit=${1-}
        if [[ ${FAKE_ACTIVE_FAIL_UNIT:-} == "$unit" ]]; then
            printf '%s\n' "${FAKE_ACTIVE_FAIL_STATE:-probe-error}"
            exit "${FAKE_ACTIVE_FAIL_RC:-71}"
        fi
        if [[ -e $state_dir/active.$unit ]]; then
            printf 'active\n'
        else
            printf 'inactive\n'
            exit 3
        fi
        ;;
    is-enabled)
        [[ ${1-} == --quiet ]] && shift
        unit=${1-}
        if [[ ${FAKE_ENABLED_FAIL_UNIT:-} == "$unit" ]]; then
            printf '%s\n' "${FAKE_ENABLED_FAIL_STATE:-probe-error}"
            exit "${FAKE_ENABLED_FAIL_RC:-72}"
        fi
        if [[ -r $state_dir/enable-state.$unit ]]; then
            state=$(<"$state_dir/enable-state.$unit")
            printf '%s\n' "$state"
            case $state in
                enabled|enabled-runtime|static) : ;;
                *) exit 1 ;;
            esac
        elif [[ $unit == keepalive.service && -r $unit_root/$unit ]] \
            && ! grep -Fq '[Install]' "$unit_root/$unit"; then
            printf 'static\n'
        else
            printf 'disabled\n'
            exit 1
        fi
        ;;
    disable)
        now=0
        rc=0
        while (($#)); do
            case $1 in
                --now) now=1 ;;
                keepalive.socket|keepalive.service)
                    rm -f -- "$state_dir/enable-state.$1"
                    ((now == 0)) || rm -f -- "$state_dir/active.$1"
                    ;;
            esac
            shift
        done
        if [[ ${FAKE_DISABLE_PRESERVE_LINKS:-0} != 1 ]]; then
            rm -f -- "$unit_root/sockets.target.wants/keepalive.socket" \
                "$unit_root/sockets.target.wants/keepalive.service" \
                "$unit_root/graphical-session.target.wants/keepalive.socket" \
                "$unit_root/graphical-session.target.wants/keepalive.service"
        fi
        [[ ${FAKE_DISABLE_FAIL:-0} == 1 ]] && rc=${FAKE_DISABLE_FAIL_RC:-74}
        exit "$rc"
        ;;
    enable)
        now=0
        runtime=0
        units=()
        while (($#)); do
            case $1 in
                --now) now=1 ;;
                --runtime) runtime=1 ;;
                *) units+=("$1") ;;
            esac
            shift
        done
        for unit in "${units[@]}"; do
            if ((runtime == 1)); then
                printf 'enabled-runtime\n' >"$state_dir/enable-state.$unit"
            else
                printf 'enabled\n' >"$state_dir/enable-state.$unit"
            fi
            ((now == 0)) || : >"$state_dir/active.$unit"
            if [[ $unit == keepalive.socket ]]; then
                mkdir -p "$unit_root/sockets.target.wants"
                ln -sfn -- ../keepalive.socket "$unit_root/sockets.target.wants/keepalive.socket"
            fi
        done
        if [[ ${FAKE_ENABLE_FAIL_ONCE:-0} == 1 && ! -e $state_dir/enable-failure-used ]]; then
            : >"$state_dir/enable-failure-used"
            exit "${FAKE_ENABLE_FAIL_RC:-75}"
        fi
        :
        ;;
    start|restart)
        for unit in "$@"; do : >"$state_dir/active.$unit"; done
        ;;
    stop)
        for unit in "$@"; do rm -f -- "$state_dir/active.$unit"; done
        ;;
    daemon-reload)
        [[ ${FAKE_DAEMON_RELOAD_FAIL:-0} == 1 ]] && exit "${FAKE_DAEMON_RELOAD_FAIL_RC:-76}"
        :
        ;;
    *)
        ;;
esac
FAKE
chmod +x "$fakebin/systemctl"

cat >"$fakebin/loginctl" <<'FAKE'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"${FAKE_SYSTEMD_STATE_DIR:?}/loginctl.calls"
exit 99
FAKE
chmod +x "$fakebin/loginctl"

# Role: Select fresh isolated HOME, manager configuration, runtime, and fake-systemd state.
new_case() {
    local name=$1
    CASE_ROOT="$TEST_TMP/$name"
    export HOME="$CASE_ROOT/home"
    export XDG_CONFIG_HOME="$CASE_ROOT/config"
    export XDG_RUNTIME_DIR="$CASE_ROOT/runtime"
    export XDG_STATE_HOME="$CASE_ROOT/state"
    export FAKE_MANAGER_CONFIG_HOME="$XDG_CONFIG_HOME"
    unset FAKE_MANAGER_RUNTIME_DIR FAKE_ACTIVE_FAIL_UNIT FAKE_ENABLED_FAIL_UNIT
    unset FAKE_SHOW_ENV_FAIL_ON_CALL FAKE_ENABLE_FAIL_ONCE FAKE_DISABLE_PRESERVE_LINKS
    unset FAKE_DISABLE_FAIL FAKE_DAEMON_RELOAD_FAIL
    export FAKE_SYSTEMD_STATE_DIR="$CASE_ROOT/fake-systemd"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" \
        "$FAKE_SYSTEMD_STATE_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    : >"$FAKE_SYSTEMD_STATE_DIR/calls"
    rm -f -- "$FAKE_SYSTEMD_STATE_DIR/show-environment-count"
}

# Role: Run an install or uninstall command with only fake systemd tools and isolated paths.
run_as_test_user() {
    local command=$1
    shift
    local -a environment=(
        "HOME=$HOME"
        "XDG_CONFIG_HOME=${XDG_CONFIG_HOME-}"
        "XDG_STATE_HOME=${XDG_STATE_HOME-}"
        "FAKE_MANAGER_CONFIG_HOME=${FAKE_MANAGER_CONFIG_HOME-}"
        "FAKE_MANAGER_RUNTIME_DIR=${FAKE_MANAGER_RUNTIME_DIR-}"
        "FAKE_SYSTEMD_STATE_DIR=$FAKE_SYSTEMD_STATE_DIR"
        "FAKE_ACTIVE_FAIL_UNIT=${FAKE_ACTIVE_FAIL_UNIT-}"
        "FAKE_ACTIVE_FAIL_RC=${FAKE_ACTIVE_FAIL_RC-}"
        "FAKE_ACTIVE_FAIL_STATE=${FAKE_ACTIVE_FAIL_STATE-}"
        "FAKE_ENABLED_FAIL_UNIT=${FAKE_ENABLED_FAIL_UNIT-}"
        "FAKE_ENABLED_FAIL_RC=${FAKE_ENABLED_FAIL_RC-}"
        "FAKE_ENABLED_FAIL_STATE=${FAKE_ENABLED_FAIL_STATE-}"
        "FAKE_SHOW_ENV_FAIL_ON_CALL=${FAKE_SHOW_ENV_FAIL_ON_CALL-}"
        "FAKE_SHOW_ENV_FAIL_RC=${FAKE_SHOW_ENV_FAIL_RC-}"
        "FAKE_ENABLE_FAIL_ONCE=${FAKE_ENABLE_FAIL_ONCE-}"
        "FAKE_ENABLE_FAIL_RC=${FAKE_ENABLE_FAIL_RC-}"
        "FAKE_DISABLE_PRESERVE_LINKS=${FAKE_DISABLE_PRESERVE_LINKS-}"
        "FAKE_DISABLE_FAIL=${FAKE_DISABLE_FAIL-}"
        "FAKE_DISABLE_FAIL_RC=${FAKE_DISABLE_FAIL_RC-}"
        "FAKE_DAEMON_RELOAD_FAIL=${FAKE_DAEMON_RELOAD_FAIL-}"
        "FAKE_DAEMON_RELOAD_FAIL_RC=${FAKE_DAEMON_RELOAD_FAIL_RC-}"
        "PATH=$fakebin:/usr/bin:/bin"
    )
    # Keep this branch usable in root-run CI while retaining an ordinary-user fast path.
    if [[ ${XDG_RUNTIME_DIR+x} ]]; then
        environment+=("XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR")
    fi
    if ((EUID == 0)); then
        test_chown_for_unprivileged "$TEST_TMP"
        chmod 755 "$TEST_TMP"
        runuser -u nobody -- env "${environment[@]}" "$command" "$@"
    else
        env "${environment[@]}" "$command" "$@"
    fi
}

# Role: Assert that a fake-systemd call log contains no mutating systemctl operation.
only_manager_probe_was_called() {
    ! grep -Eq -- '--user (disable|enable|start|stop|restart|daemon-reload)( |$)' \
        "$FAKE_SYSTEMD_STATE_DIR/calls"
}

# Role: Assert a symlink's literal target without resolving or normalizing it.
assert_link_target() {
    local path=$1 expected=$2 message=$3 actual
    if actual=$(readlink -- "$path" 2>/dev/null); then
        :
    else
        actual='<missing>'
    fi
    assert_eq "$expected" "$actual" "$message"
}

# Role: Return success only when an isolated install has no managed source tree.
share_absent() {
    [[ ! -e $HOME/.local/share/keepalive-manager && ! -L $HOME/.local/share/keepalive-manager ]]
}

# Role: Return success only when a path is absent, including as a dangling symlink.
path_absent() {
    [[ ! -e $1 && ! -L $1 ]]
}

# Role: Return success only when the fake loginctl endpoint was never called.
loginctl_was_not_called() {
    [[ ! -s $FAKE_SYSTEMD_STATE_DIR/loginctl.calls ]]
}

# Role: Return success only when every reserved path in one unit root is absent or a symlink/file.
reserved_paths_are_not_directories() {
    local units=$1 relative
    for relative in \
        keepalive.socket keepalive.service \
        sockets.target.wants/keepalive.socket sockets.target.wants/keepalive.service \
        graphical-session.target.wants/keepalive.socket graphical-session.target.wants/keepalive.service; do
        [[ ! -d $units/$relative || -L $units/$relative ]] || return 1
    done
}

# Role: Install a baseline tree and make its result explicit in the test output.
install_baseline() {
    local label=$1 rc=0
    run_as_test_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/$label.out" \
        2>"$CASE_ROOT/$label.err" || rc=$?
    assert_eq 0 "$rc" "$label baseline installation succeeds"
}

# Role: Run one failed installer probe case and assert it stopped before systemd mutation.
assert_install_probe_failure() {
    local label=$1 expected_rc=$2 expected_text=$3 rc=0
    run_as_test_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
    assert_eq "$expected_rc" "$rc" "$label probe failure reaches the caller"
    assert_contains "$CASE_ROOT/err" "$expected_text" "$label probe failure is explained"
    assert_true "$label leaves no installed source tree" share_absent
    assert_true "$label stops before systemd mutation" only_manager_probe_was_called
}

# Unexpected active-state failures are fatal, rather than being mistaken for inactive units.
new_case install-active-probe
export FAKE_ACTIVE_FAIL_UNIT=keepalive.service FAKE_ACTIVE_FAIL_RC=41
assert_install_probe_failure 'service active-state' 1 'could not determine whether keepalive.service is active'

# Unexpected enabled-state failures are fatal, rather than being mistaken for disabled units.
new_case install-enabled-probe
export FAKE_ENABLED_FAIL_UNIT=keepalive.socket FAKE_ENABLED_FAIL_RC=42
assert_install_probe_failure 'socket enabled-state' 1 'could not determine whether keepalive.socket is enabled'

# The other units use the same probes and must fail closed as well.
new_case install-socket-active-probe
export FAKE_ACTIVE_FAIL_UNIT=keepalive.socket FAKE_ACTIVE_FAIL_RC=43
assert_install_probe_failure 'socket active-state' 1 'could not determine whether keepalive.socket is active'

new_case install-service-enabled-probe
export FAKE_ENABLED_FAIL_UNIT=keepalive.service FAKE_ENABLED_FAIL_RC=44
assert_install_probe_failure 'service enabled-state' 1 'could not determine whether keepalive.service is enabled'

# An arbitrary pre-existing share must never be treated as an old installation and deleted.
new_case install-unrecognized-share
unrecognized_install="$HOME/.local/share/keepalive-manager"
mkdir -p "$unrecognized_install"
printf 'user-owned sentinel\n' >"$unrecognized_install/sentinel"
rc=0
run_as_test_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 1 "$rc" 'installer refuses an unrecognized pre-existing share'
assert_contains "$CASE_ROOT/err" 'not a recognized Keep Alive Manager installation' \
    'unrecognized share refusal explains that the tree is preserved'
assert_eq 'user-owned sentinel' "$(<"$unrecognized_install/sentinel")" \
    'installer preserves every byte of the unrecognized share'
assert_true 'unrecognized share is rejected before systemd mutation' only_manager_probe_was_called

# A configuration root equal to or nested in the installed share is unsafe before mkdir/copy.
new_case overlap-installed-share
export XDG_CONFIG_HOME="$HOME/.local/share/keepalive-manager"
export FAKE_MANAGER_CONFIG_HOME="$XDG_CONFIG_HOME"
rc=0
run_as_test_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 1 "$rc" 'configuration overlapping the installed share is rejected'
assert_contains "$CASE_ROOT/err" 'XDG_CONFIG_HOME and the installed source tree must not overlap' \
    'installed-share overlap explains the rejected layout'
assert_true 'installed-share overlap leaves no source tree' share_absent
assert_true 'installed-share overlap stops before systemd mutation' only_manager_probe_was_called

# The checkout source root is also never a valid manager configuration or unit-root parent.
new_case overlap-checkout-root
export XDG_CONFIG_HOME="$TEST_ROOT"
export FAKE_MANAGER_CONFIG_HOME="$XDG_CONFIG_HOME"
rc=0
run_as_test_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 1 "$rc" 'configuration overlapping the checkout source root is rejected'
assert_contains "$CASE_ROOT/err" 'installer source tree must not overlap' \
    'checkout-root overlap explains the rejected layout'
assert_true 'checkout-root overlap leaves no installed source tree' share_absent
assert_true 'checkout-root overlap stops before systemd mutation' only_manager_probe_was_called

# A manager-only custom runtime must not silently select a different runtime when the caller omitted it.
new_case manager-runtime-without-caller
manager_runtime="$CASE_ROOT/manager-runtime"
mkdir -p "$manager_runtime"
chmod 700 "$manager_runtime"
unset XDG_RUNTIME_DIR
export FAKE_MANAGER_RUNTIME_DIR="$manager_runtime"
rc=0
run_as_test_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 1 "$rc" 'manager-only custom runtime with an unset caller runtime is rejected'
assert_contains "$CASE_ROOT/err" 'XDG_RUNTIME_DIR' \
    'manager-only runtime mismatch identifies the runtime boundary'
assert_true 'manager-only runtime mismatch leaves no source tree' share_absent
assert_true 'manager-only runtime mismatch stops before systemd mutation' only_manager_probe_was_called

# Reinstalling after a custom-XDG move cleans sockets-target links recorded by the old tree.
new_case stale-prior-custom-sockets-links
old_config="$CASE_ROOT/old-config"
new_config="$CASE_ROOT/new-config"
mkdir -p "$old_config" "$new_config"
export XDG_CONFIG_HOME="$old_config" FAKE_MANAGER_CONFIG_HOME="$old_config"
install_baseline 'old-custom'
old_units="$old_config/systemd/user"
assert_true 'old custom install creates its sockets-target socket link' \
    test -L "$old_units/sockets.target.wants/keepalive.socket"
mkdir -p "$old_units/sockets.target.wants"
ln -s ../keepalive.service "$old_units/sockets.target.wants/keepalive.service"
export XDG_CONFIG_HOME="$new_config" FAKE_MANAGER_CONFIG_HOME="$new_config"
rc=0
run_as_test_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/new.out" \
    2>"$CASE_ROOT/new.err" || rc=$?
assert_eq 0 "$rc" 'custom-XDG reinstall succeeds'
new_units="$new_config/systemd/user"
assert_true 'stale prior custom sockets-target socket link is removed' \
    path_absent "$old_units/sockets.target.wants/keepalive.socket"
assert_true 'stale prior custom sockets-target service link is removed' \
    path_absent "$old_units/sockets.target.wants/keepalive.service"
assert_true 'new custom root receives the sockets-target socket link' \
    test -L "$new_units/sockets.target.wants/keepalive.socket"

# A failed replacement must restore every legacy graphical-target and sockets-target link byte-for-byte.
new_case rollback-target-links
install_baseline 'before-rollback'
rollback_units="$XDG_CONFIG_HOME/systemd/user"
mkdir -p "$rollback_units/sockets.target.wants" "$rollback_units/graphical-session.target.wants"
rm -f -- "$rollback_units/sockets.target.wants/keepalive.socket"
ln -s ../keepalive.socket "$rollback_units/sockets.target.wants/keepalive.socket"
ln -s ../keepalive.service "$rollback_units/sockets.target.wants/keepalive.service"
ln -s ../../legacy-graphical.socket "$rollback_units/graphical-session.target.wants/keepalive.socket"
ln -s legacy-graphical.service "$rollback_units/graphical-session.target.wants/keepalive.service"
export FAKE_ENABLE_FAIL_ONCE=1 FAKE_ENABLE_FAIL_RC=57
rc=0
run_as_test_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/rollback.out" \
    2>"$CASE_ROOT/rollback.err" || rc=$?
assert_eq 57 "$rc" 'activation failure enters transactional rollback'
assert_link_target "$rollback_units/sockets.target.wants/keepalive.socket" '../keepalive.socket' \
    'rollback restores the exact sockets-target socket link'
assert_link_target "$rollback_units/sockets.target.wants/keepalive.service" '../keepalive.service' \
    'rollback restores the exact sockets-target service link'
assert_link_target "$rollback_units/graphical-session.target.wants/keepalive.socket" '../../legacy-graphical.socket' \
    'rollback restores the exact graphical-target socket link'
assert_link_target "$rollback_units/graphical-session.target.wants/keepalive.service" 'legacy-graphical.service' \
    'rollback restores the exact graphical-target service link'
assert_true 'rollback leaves all reserved target paths non-directory' \
    reserved_paths_are_not_directories "$rollback_units"

# Directory-shaped unit files fail installer preflight before any probe or mutation.
new_case install-unit-directory
install_units="$XDG_CONFIG_HOME/systemd/user"
mkdir -p "$install_units"
mkdir "$install_units/keepalive.socket"
rc=0
run_as_test_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 1 "$rc" 'directory-shaped socket unit path fails install preflight'
assert_contains "$CASE_ROOT/err" 'exists but is not a regular file or symlink' \
    'directory-shaped unit path explains the preflight failure'
assert_true 'directory-shaped unit path is rejected before systemd mutation' only_manager_probe_was_called

# Directory-shaped enablement paths fail installer preflight before removing old links.
new_case install-link-directory
install_units="$XDG_CONFIG_HOME/systemd/user"
mkdir -p "$install_units/sockets.target.wants/keepalive.socket"
rc=0
run_as_test_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 1 "$rc" 'directory-shaped enablement link fails install preflight'
assert_contains "$CASE_ROOT/err" 'reserved systemd enablement-link path is unsafe' \
    'directory-shaped enablement path explains the preflight failure'
assert_true 'directory-shaped enablement path is rejected before systemd mutation' only_manager_probe_was_called

# Uninstall validates all roots before systemctl disable can remove the first link.
new_case uninstall-link-directory
install_baseline 'uninstall-preflight'
uninstall_units="$XDG_CONFIG_HOME/systemd/user"
rm -f -- "$uninstall_units/sockets.target.wants/keepalive.socket"
mkdir -p "$uninstall_units/sockets.target.wants/keepalive.socket"
: >"$FAKE_SYSTEMD_STATE_DIR/calls"
rm -f -- "$FAKE_SYSTEMD_STATE_DIR/show-environment-count"
rc=0
run_as_test_user "$TEST_ROOT/scripts/uninstall.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 1 "$rc" 'directory-shaped uninstall link fails preflight'
assert_contains "$CASE_ROOT/err" 'reserved unit path is a directory' \
    'uninstall directory preflight explains the refusal'
assert_true 'uninstall directory preflight runs before systemd mutation' only_manager_probe_was_called
assert_true 'uninstall directory preflight preserves the installed source tree' \
    test -d "$HOME/.local/share/keepalive-manager"

# An unexpected manager status-query failure remains fatal even when --force is supplied.
new_case uninstall-status-query-failure
install_baseline 'status-query'
status_units="$XDG_CONFIG_HOME/systemd/user"
mkdir -p "$status_units/sockets.target.wants" "$status_units/graphical-session.target.wants"
ln -sfn -- ../keepalive.service "$status_units/sockets.target.wants/keepalive.service"
ln -sfn -- ../../legacy.socket "$status_units/graphical-session.target.wants/keepalive.socket"
ln -sfn -- legacy.service "$status_units/graphical-session.target.wants/keepalive.service"
export FAKE_SHOW_ENV_FAIL_ON_CALL=2 FAKE_SHOW_ENV_FAIL_RC=61
rm -f -- "$FAKE_SYSTEMD_STATE_DIR/show-environment-count"
: >"$FAKE_SYSTEMD_STATE_DIR/calls"
rc=0
run_as_test_user "$TEST_ROOT/scripts/uninstall.sh" --force >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 61 "$rc" 'uninstall status-query failure aborts even with --force'
assert_true 'status-query failure preserves the installed source tree' \
    test -d "$HOME/.local/share/keepalive-manager"
assert_true 'status-query failure preserves the installed socket unit' \
    test -f "$status_units/keepalive.socket"
assert_link_target "$status_units/sockets.target.wants/keepalive.socket" '../keepalive.socket' \
    'status-query rollback restores the sockets-target socket link'
assert_link_target "$status_units/sockets.target.wants/keepalive.service" '../keepalive.service' \
    'status-query rollback restores the sockets-target service link'
assert_link_target "$status_units/graphical-session.target.wants/keepalive.socket" '../../legacy.socket' \
    'status-query rollback restores the graphical-target socket link'
assert_link_target "$status_units/graphical-session.target.wants/keepalive.service" 'legacy.service' \
    'status-query rollback restores the graphical-target service link'
# The stop attempt may already have reached systemd; the safety invariant here is that
# an untrusted status result cannot authorize executable-file removal under --force.

# An unexpected active probe during uninstall is equally fatal under --force.
new_case uninstall-active-query-failure
install_baseline 'active-query'
active_units="$XDG_CONFIG_HOME/systemd/user"
export FAKE_ACTIVE_FAIL_UNIT=keepalive.service FAKE_ACTIVE_FAIL_RC=62
rm -f -- "$FAKE_SYSTEMD_STATE_DIR/show-environment-count"
: >"$FAKE_SYSTEMD_STATE_DIR/calls"
rc=0
run_as_test_user "$TEST_ROOT/scripts/uninstall.sh" --force >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 62 "$rc" 'uninstall active-query failure aborts even with --force'
assert_true 'active-query failure preserves the installed source tree' \
    test -d "$HOME/.local/share/keepalive-manager"
assert_true 'active-query failure preserves the installed service unit' \
    test -f "$active_units/keepalive.service"
assert_link_target "$active_units/sockets.target.wants/keepalive.socket" '../keepalive.socket' \
    'active-query rollback restores persistent socket enablement'
# The stop attempt may already have reached systemd; no executable files may be removed.

# A completed file removal with a failed manager reload is not reported as success.
new_case uninstall-reload-failure
install_baseline 'reload-failure'
export FAKE_DAEMON_RELOAD_FAIL=1 FAKE_DAEMON_RELOAD_FAIL_RC=76
rc=0
run_as_test_user "$TEST_ROOT/scripts/uninstall.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 76 "$rc" 'uninstall returns the daemon-reload failure status'
assert_contains "$CASE_ROOT/err" 'daemon-reload failed' \
    'daemon-reload failure is reported as an error'
assert_false 'daemon-reload failure suppresses the success message' \
    grep -Fq 'Keep Alive Manager removed' "$CASE_ROOT/out"

# A replacement command link is not removed merely because the managed share is removed.
new_case replacement-command-link
install_baseline 'replacement'
replacement="$CASE_ROOT/replacement-command"
printf '# replacement\n' >"$replacement"
rm -f -- "$HOME/.local/bin/keepalive"
ln -s "$replacement" "$HOME/.local/bin/keepalive"
rc=0
run_as_test_user "$TEST_ROOT/scripts/uninstall.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 0 "$rc" 'uninstall succeeds with a replacement command link'
assert_link_target "$HOME/.local/bin/keepalive" "$replacement" \
    'uninstall preserves a replacement command link with a different target'
assert_true 'uninstall removes the recognized managed share beside a replacement link' share_absent

# An unrecognized share is retained, along with a command replacement beside it.
new_case unrecognized-share
unrecognized="$HOME/.local/share/keepalive-manager"
mkdir -p "$unrecognized"
printf 'user-owned sentinel\n' >"$unrecognized/sentinel"
replacement="$CASE_ROOT/unrecognized-command"
printf '# unrecognized replacement\n' >"$replacement"
mkdir -p "$HOME/.local/bin"
ln -s "$replacement" "$HOME/.local/bin/keepalive"
rc=0
run_as_test_user "$TEST_ROOT/scripts/uninstall.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 0 "$rc" 'uninstall succeeds with an unrecognized share directory'
assert_true 'uninstall preserves an unrecognized share directory' \
    test -f "$unrecognized/sentinel"
assert_link_target "$HOME/.local/bin/keepalive" "$replacement" \
    'uninstall preserves the replacement command beside an unrecognized share'

assert_true 'the safety harness never invokes loginctl' loginctl_was_not_called

test_finish
