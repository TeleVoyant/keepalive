#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup

if ((EUID == 0)) && { ! command -v runuser >/dev/null 2>&1 || ! id nobody >/dev/null 2>&1; }; then
    printf 'ok 1 - install lifecycle test skipped: no usable unprivileged account runner\n'
    TEST_COUNT=1
    test_finish
    exit
fi

fakebin="$TEST_TMP/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" >>"$FAKE_SYSTEMD_STATE_DIR/calls"
[[ ${1-} == --user ]] && shift
command=${1-}
[[ -z $command ]] || shift
fail=0
if [[ -n ${FAKE_SYSTEMCTL_FAIL_ONCE:-} && $command == "$FAKE_SYSTEMCTL_FAIL_ONCE" \
    && ! -e $FAKE_SYSTEMD_STATE_DIR/failure-used ]]; then
    : >"$FAKE_SYSTEMD_STATE_DIR/failure-used"
    fail=1
fi
unit_root=$(readlink -m -- "${FAKE_MANAGER_CONFIG_HOME:-$HOME/.config}")/systemd/user

case $command in
    show-environment)
        printf 'HOME=%s\n' "$HOME"
        [[ -z ${FAKE_MANAGER_CONFIG_HOME:-} ]] \
            || printf 'XDG_CONFIG_HOME=%s\n' "$FAKE_MANAGER_CONFIG_HOME"
        printf 'XDG_RUNTIME_DIR=%s\n' "$XDG_RUNTIME_DIR"
        ;;
    is-active)
        [[ ${1-} == --quiet ]] && shift
        if [[ -e $FAKE_SYSTEMD_STATE_DIR/active.${1-} ]]; then
            printf 'active\n'
        else
            printf 'inactive\n'
            exit 3
        fi
        ;;
    is-enabled)
        [[ ${1-} == --quiet ]] && shift
        unit=${1-}
        if [[ -r $FAKE_SYSTEMD_STATE_DIR/enable-state.$unit ]]; then
            state=$(<"$FAKE_SYSTEMD_STATE_DIR/enable-state.$unit")
            printf '%s\n' "$state"
            case $state in enabled|enabled-runtime|static) : ;; *) exit 1 ;; esac
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
        while (($#)); do
            case $1 in
                --now) now=1 ;;
                keepalive.socket|keepalive.service)
                    rm -f -- "$FAKE_SYSTEMD_STATE_DIR/enable-state.$1"
                    ((now == 0)) || rm -f -- "$FAKE_SYSTEMD_STATE_DIR/active.$1"
                    ;;
            esac
            shift
        done
        rm -f -- "$unit_root/sockets.target.wants/keepalive.socket" \
            "$unit_root/sockets.target.wants/keepalive.service" \
            "$unit_root/graphical-session.target.wants/keepalive.socket" \
            "$unit_root/graphical-session.target.wants/keepalive.service"
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
                printf 'enabled-runtime\n' >"$FAKE_SYSTEMD_STATE_DIR/enable-state.$unit"
            else
                printf 'enabled\n' >"$FAKE_SYSTEMD_STATE_DIR/enable-state.$unit"
            fi
            ((now == 0)) || : >"$FAKE_SYSTEMD_STATE_DIR/active.$unit"
            if [[ $unit == keepalive.socket ]]; then
                mkdir -p "$unit_root/sockets.target.wants"
                ln -sfn ../keepalive.socket "$unit_root/sockets.target.wants/keepalive.socket"
            fi
        done
        ;;
    start|restart)
        for unit in "$@"; do : >"$FAKE_SYSTEMD_STATE_DIR/active.$unit"; done
        ;;
    stop)
        for unit in "$@"; do rm -f -- "$FAKE_SYSTEMD_STATE_DIR/active.$unit"; done
        ;;
    daemon-reload) : ;;
    *) : ;;
esac
((fail == 0)) || exit 55
FAKE
chmod +x "$fakebin/systemctl"

# Role: Select fresh isolated HOME/XDG/systemd state for one installer scenario.
prepare_install_case() {
    local name=$1
    CASE_ROOT="$TEST_TMP/$name"
    export HOME="$CASE_ROOT/home"
    export XDG_CONFIG_HOME="$CASE_ROOT/config"
    export XDG_RUNTIME_DIR="$CASE_ROOT/runtime"
    export XDG_STATE_HOME="$CASE_ROOT/state"
    export FAKE_MANAGER_CONFIG_HOME=$XDG_CONFIG_HOME
    export FAKE_SYSTEMD_STATE_DIR="$CASE_ROOT/fake-systemd"
    unset FAKE_SYSTEMCTL_FAIL_ONCE
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR" "$XDG_STATE_HOME" \
        "$FAKE_SYSTEMD_STATE_DIR"
    chmod 700 "$XDG_RUNTIME_DIR"
    : >"$FAKE_SYSTEMD_STATE_DIR/calls"
}

# Role: Run an installer command as the unprivileged test account with the fake manager.
run_install_user() {
    local command=$1
    test_chown_for_unprivileged "$TEST_TMP"
    chmod 755 "$TEST_TMP"
    if ((EUID == 0)); then
        runuser -u nobody -- env \
            HOME="$HOME" XDG_CONFIG_HOME="${XDG_CONFIG_HOME-}" \
            XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_STATE_HOME="$XDG_STATE_HOME" \
            FAKE_MANAGER_CONFIG_HOME="${FAKE_MANAGER_CONFIG_HOME-}" \
            FAKE_SYSTEMD_STATE_DIR="$FAKE_SYSTEMD_STATE_DIR" \
            FAKE_SYSTEMCTL_FAIL_ONCE="${FAKE_SYSTEMCTL_FAIL_ONCE-}" \
            PATH="$fakebin:/usr/bin:/bin" "$command"
    else
        env HOME="$HOME" XDG_CONFIG_HOME="${XDG_CONFIG_HOME-}" \
            XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_STATE_HOME="$XDG_STATE_HOME" \
            FAKE_MANAGER_CONFIG_HOME="${FAKE_MANAGER_CONFIG_HOME-}" \
            FAKE_SYSTEMD_STATE_DIR="$FAKE_SYSTEMD_STATE_DIR" \
            FAKE_SYSTEMCTL_FAIL_ONCE="${FAKE_SYSTEMCTL_FAIL_ONCE-}" \
            PATH="$fakebin:/usr/bin:/bin" "$command"
    fi
}

# Role: Return success when an installer transaction left no staging or backup directory.
install_debris_absent() {
    ! compgen -G "$HOME/.local/share/.keepalive-manager.*" >/dev/null \
        && ! compgen -G "$XDG_CONFIG_HOME/systemd/.keepalive-manager.*" >/dev/null
}

prepare_install_case mismatch
caller_config=$XDG_CONFIG_HOME
export FAKE_MANAGER_CONFIG_HOME="$CASE_ROOT/manager-config"
rc=0
run_install_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/out" 2>"$CASE_ROOT/err" || rc=$?
assert_eq 1 "$rc" 'installer rejects a shell and user-manager config-home mismatch'
assert_contains "$CASE_ROOT/err" 'shell and systemd user manager resolve different XDG_CONFIG_HOME paths' \
    'config-home mismatch explains the required login-session fix'
assert_false 'config-home mismatch makes no source installation' \
    test -e "$HOME/.local/share/keepalive-manager"
assert_eq '--user show-environment' "$(<"$FAKE_SYSTEMD_STATE_DIR/calls")" \
    'config-home mismatch stops before mutating systemd state'
export XDG_CONFIG_HOME=$caller_config

prepare_install_case migration
custom_units="$XDG_CONFIG_HOME/systemd/user"
legacy_units="$HOME/.config/systemd/user"
mkdir -p "$custom_units/graphical-session.target.wants" \
    "$legacy_units/graphical-session.target.wants" "$XDG_CONFIG_HOME/keepalive/profile"
ln -s ../keepalive.socket "$custom_units/graphical-session.target.wants/keepalive.socket"
ln -s ../keepalive.service "$custom_units/graphical-session.target.wants/keepalive.service"
printf legacy >"$legacy_units/keepalive.socket"
printf legacy >"$legacy_units/keepalive.service"
ln -s ../keepalive.socket "$legacy_units/graphical-session.target.wants/keepalive.socket"
printf retained >"$XDG_CONFIG_HOME/keepalive/profile/sentinel"
run_install_user "$TEST_ROOT/scripts/install.sh" >/dev/null
assert_file "$custom_units/keepalive.socket" 'custom manager config receives the socket unit'
assert_file "$custom_units/keepalive.service" 'custom manager config receives the service unit'
assert_false 'custom manager graphical socket link is migrated away' \
    test -e "$custom_units/graphical-session.target.wants/keepalive.socket"
assert_false 'legacy default unit file is removed after custom-manager install' \
    test -e "$legacy_units/keepalive.socket"
assert_true 'socket enablement creates the sockets.target link' \
    test -L "$custom_units/sockets.target.wants/keepalive.socket"
assert_contains "$FAKE_SYSTEMD_STATE_DIR/calls" 'enable --now keepalive.socket' \
    'installation enables only the socket entrypoint'
run_install_user "$TEST_ROOT/scripts/uninstall.sh" >/dev/null
assert_false 'uninstall removes the installed socket unit' test -e "$custom_units/keepalive.socket"
assert_file "$XDG_CONFIG_HOME/keepalive/profile/sentinel" \
    'uninstall retains the persistent profile'

prepare_install_case alias
export XDG_CONFIG_HOME="$HOME/.config/"
export FAKE_MANAGER_CONFIG_HOME=$XDG_CONFIG_HOME
mkdir -p "$HOME/.config"
run_install_user "$TEST_ROOT/scripts/install.sh" >/dev/null
assert_file "$HOME/.config/systemd/user/keepalive.socket" \
    'trailing-slash config alias does not delete the newly installed socket'
assert_file "$HOME/.config/systemd/user/keepalive.service" \
    'trailing-slash config alias does not delete the newly installed service'

prepare_install_case rollback
run_install_user "$TEST_ROOT/scripts/install.sh" >/dev/null
: >"$FAKE_SYSTEMD_STATE_DIR/active.keepalive.service"
run_install_user "$TEST_ROOT/scripts/install.sh" >/dev/null
assert_contains "$FAKE_SYSTEMD_STATE_DIR/calls" 'restart keepalive.service' \
    'updating an active daemon restarts it onto the new code'

installed_root="$HOME/.local/share/keepalive-manager"
printf '\ninstalled-tree-sentinel\n' >>"$installed_root/README.md"
run_install_user "$installed_root/scripts/install.sh" >/dev/null
assert_contains "$installed_root/README.md" 'installed-tree-sentinel' \
    'reinstalling from the installed tree stages its source before swapping it'

printf '\nrollback-source-sentinel\n' >>"$installed_root/README.md"
printf '\n# rollback-unit-sentinel\n' >>"$XDG_CONFIG_HOME/systemd/user/keepalive.service"
cp -f "$installed_root/README.md" "$CASE_ROOT/expected-readme"
cp -f "$XDG_CONFIG_HOME/systemd/user/keepalive.service" "$CASE_ROOT/expected-service"
printf '#!/usr/bin/env bash\n' >"$HOME/custom-old-command"
chmod +x "$HOME/custom-old-command"
ln -sfn "$HOME/custom-old-command" "$HOME/.local/bin/keepalive"
printf enabled >"$FAKE_SYSTEMD_STATE_DIR/enable-state.keepalive.socket"
: >"$FAKE_SYSTEMD_STATE_DIR/active.keepalive.socket"
: >"$FAKE_SYSTEMD_STATE_DIR/active.keepalive.service"
rm -f -- "$FAKE_SYSTEMD_STATE_DIR/failure-used" \
    "$FAKE_SYSTEMD_STATE_DIR/enable-state.keepalive.service"
export FAKE_SYSTEMCTL_FAIL_ONCE=enable
rc=0
run_install_user "$TEST_ROOT/scripts/install.sh" >"$CASE_ROOT/rollback.out" \
    2>"$CASE_ROOT/rollback.err" || rc=$?
assert_eq 55 "$rc" 'activation failure makes the transactional upgrade fail'
assert_true 'failed upgrade restores the previous installed source bytes' \
    files_equal "$CASE_ROOT/expected-readme" "$installed_root/README.md"
assert_true 'failed upgrade restores the previous service unit bytes' \
    files_equal "$CASE_ROOT/expected-service" "$XDG_CONFIG_HOME/systemd/user/keepalive.service"
assert_eq "$HOME/custom-old-command" "$(readlink "$HOME/.local/bin/keepalive")" \
    'failed upgrade restores the previous command symlink target'
assert_eq enabled "$(<"$FAKE_SYSTEMD_STATE_DIR/enable-state.keepalive.socket")" \
    'failed upgrade restores persistent socket enablement'
assert_true 'failed upgrade restores active socket state' \
    test -e "$FAKE_SYSTEMD_STATE_DIR/active.keepalive.socket"
assert_true 'failed upgrade restores active service state' \
    test -e "$FAKE_SYSTEMD_STATE_DIR/active.keepalive.service"
assert_false 'rollback does not try to enable the restored static service' \
    grep -Fxq -- '--user enable keepalive.service' "$FAKE_SYSTEMD_STATE_DIR/calls"
assert_true 'failed and successful installs clean every transaction directory' \
    install_debris_absent

test_finish
