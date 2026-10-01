#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup

fakebin="$TEST_TMP/fakebin"
mkdir -p "$fakebin"
cat >"$fakebin/systemctl" <<'FAKE'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$HOME/systemctl.calls"
case $* in
    '--user show-environment')
        printf 'HOME=%s\nXDG_CONFIG_HOME=%s\nXDG_RUNTIME_DIR=%s\n' \
            "$HOME" "$XDG_CONFIG_HOME" "$XDG_RUNTIME_DIR"
        ;;
    '--user is-active '*) printf 'inactive\n'; exit 3 ;;
    '--user is-enabled '*) printf 'disabled\n'; exit 1 ;;
esac
FAKE
chmod +x "$fakebin/systemctl"

# Role: Execute installer/uninstaller as an unprivileged account even when CI itself runs as root.
run_unprivileged() {
    local command=$1
    if ((EUID == 0)); then
        command -v runuser >/dev/null 2>&1 || return 77
        test_chown_for_unprivileged "$TEST_TMP"
        chmod 755 "$TEST_TMP"
        runuser -u nobody -- env \
            HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_STATE_HOME="$XDG_STATE_HOME" \
            PATH="$fakebin:/usr/bin:/bin" "$command"
    else
        env HOME="$HOME" XDG_CONFIG_HOME="$XDG_CONFIG_HOME" XDG_RUNTIME_DIR="$XDG_RUNTIME_DIR" XDG_STATE_HOME="$XDG_STATE_HOME" \
            PATH="$fakebin:/usr/bin:/bin" "$command"
    fi
}

# A missing runuser is the only supported skip. Installer failures must fail this test.
install_rc=0
run_unprivileged "$TEST_ROOT/scripts/install.sh" >"$TEST_TMP/install.out" 2>"$TEST_TMP/install.err" || install_rc=$?
if ((install_rc != 0 && install_rc != 77)); then
    sed 's/^/# installer stderr: /' "$TEST_TMP/install.err" >&2
fi
if ((install_rc == 77)); then
    printf 'ok 1 - installer layout test skipped: no usable unprivileged execution path\n'
    TEST_COUNT=1
else
    assert_eq 0 "$install_rc" 'installer succeeds with manager-scoped XDG configuration'
    assert_file "$HOME/.local/share/keepalive-manager/README.md" 'installer copies README into per-user share'
    assert_true 'installer creates keepalive command symlink' test -L "$HOME/.local/bin/keepalive"
    assert_file "$XDG_CONFIG_HOME/systemd/user/keepalive.socket" 'installer copies socket under manager config home'
    assert_file "$XDG_CONFIG_HOME/systemd/user/keepalive.service" 'installer copies static service under manager config home'
    assert_contains "$HOME/systemctl.calls" 'enable --now keepalive.socket' 'installer enables only socket activation entrypoint'
    run_unprivileged "$TEST_ROOT/scripts/uninstall.sh" >/dev/null
    assert_false 'uninstaller removes keepalive command symlink' test -e "$HOME/.local/bin/keepalive"
fi

test_finish
