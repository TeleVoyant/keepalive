#!/usr/bin/env bash
# Install Keep Alive Manager for the current user only; root is intentionally unsupported.
set -Eeuo pipefail

# Role: Print an installer error and terminate cleanly.
die() { printf 'install: ERROR: %s\n' "$*" >&2; exit 1; }

# Role: Resolve the project root from this installer location.
project_root() {
    local self
    self=$(readlink -f -- "${BASH_SOURCE[0]}")
    printf '%s' "${self%/scripts/install.sh}"
}

# Role: Install source, symlink, and user systemd units without requiring sudo.
main() {
    ((EUID != 0)) || die 'do not run this installer with sudo/root'
    command -v systemctl >/dev/null 2>&1 || die 'systemctl is required for user-service installation'

    local root share bin units
    root=$(project_root)
    share="$HOME/.local/share/keepalive-manager"
    bin="$HOME/.local/bin"
    units="$HOME/.config/systemd/user"

    mkdir -p "$share" "$bin" "$units"
    # ${share:?} so an empty expansion aborts instead of building a path at the filesystem root.
    rm -rf -- "${share:?}/lib" "${share:?}/systemd" "${share:?}/docs" "${share:?}/tests" "${share:?}/scripts"
    cp -a -- "$root/lib" "$root/systemd" "$root/docs" "$root/tests" "$root/scripts" "$share/"
    cp -f -- "$root/keepalive" "$root/README.md" "$share/"
    chmod +x "$share/keepalive" "$share/scripts/"*.sh "$share/tests/"*.sh 2>/dev/null || true
    ln -sfn "$share/keepalive" "$bin/keepalive"
    cp -f -- "$root/systemd/keepalive.service" "$root/systemd/keepalive.socket" "$units/"

    systemctl --user daemon-reload
    systemctl --user enable --now keepalive.socket

    # A running daemon has already sourced the previous modules and keeps executing them
    # until restarted, so an update would otherwise leave new clients talking to old code.
    if systemctl --user is-active --quiet keepalive.service; then
        printf 'Restarting the running daemon to load the updated code.\n'
        systemctl --user restart keepalive.service
    fi

    printf 'Installed Keep Alive Manager.\n'
    printf 'Command: %s/keepalive\n' "$bin"
    printf 'Try: keepalive doctor\n'
}

main "$@"
