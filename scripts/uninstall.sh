#!/usr/bin/env bash
# Remove the current user's Keep Alive installation without touching AI/Konsole processes.
set -Eeuo pipefail

# Role: Remove installed user units, binary link, and application source tree.
main() {
    ((EUID != 0)) || { printf 'uninstall: do not run as root\n' >&2; exit 1; }
    systemctl --user disable --now keepalive.socket keepalive.service >/dev/null 2>&1 || true
    rm -f -- "$HOME/.config/systemd/user/keepalive.socket" "$HOME/.config/systemd/user/keepalive.service"
    rm -f -- "$HOME/.local/bin/keepalive"
    rm -rf -- "$HOME/.local/share/keepalive-manager"
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    printf 'Keep Alive Manager removed. Persistent profile left at %s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/keepalive"
}

main "$@"
