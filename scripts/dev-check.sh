#!/usr/bin/env bash
# Run maintainability, syntax, unit/mock-integration, and systemd unit checks.
set -Eeuo pipefail
ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)

# Role: Print a consistent validation section heading.
section() { printf '\n==> %s\n' "$*"; }

# Role: Validate Bash syntax for every executable/source/test script in the project.
check_syntax() {
    section 'Bash syntax'
    local file
    while IFS= read -r -d '' file; do
        bash -n "$file"
        printf 'ok  %s\n' "${file#$ROOT/}"
    done < <(find "$ROOT" -type f \( -name '*.sh' -o -name keepalive \) -print0 | sort -z)
}

# Role: Run ShellCheck when installed while remaining usable on dependency-minimal hosts.
check_shellcheck() {
    section 'ShellCheck (optional)'
    # CI runs ShellCheck as a separate non-blocking job, because the codebase has never
    # been verified against it: no ShellCheck is available in the development environment.
    if [[ -n ${KEEPALIVE_SKIP_SHELLCHECK:-} ]]; then
        printf 'skip: disabled by KEEPALIVE_SKIP_SHELLCHECK\n'
        return 0
    fi
    if ! command -v shellcheck >/dev/null 2>&1; then
        printf 'skip: shellcheck is not installed\n'
        return 0
    fi
    local -a files=()
    mapfile -d '' -t files < <(find "$ROOT" -type f \( -name '*.sh' -o -name keepalive \) -print0)
    shellcheck -x "${files[@]}"
}

# Role: Confirm every documented version string still matches the one the tool reports.
# The version appears in the executable and in four documents. Nothing but habit kept them
# aligned, and a release that ships mismatched numbers is confusing in a way no test caught.
check_version() {
    section 'Version consistency'
    local declared file found status=0
    declared=$(sed -n "s/^KEEPALIVE_VERSION='\(.*\)'/\1/p" "$ROOT/keepalive")
    if [[ -z $declared ]]; then
        printf 'FAIL: keepalive does not declare KEEPALIVE_VERSION\n' >&2
        return 1
    fi
    for file in README.md VALIDATION.md docs/VALIDATION.md .agent/README.md; do
        found=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/$file" | head -1)
        if [[ $found != "$declared" ]]; then
            printf 'FAIL: %s declares %s, expected %s\n' "$file" "${found:-none}" "$declared" >&2
            status=1
            continue
        fi
        printf 'ok  %s\n' "$file"
    done
    # A release tag is cut from CHANGELOG.md, so an unreleased version there is a mistake.
    if ! grep -q "^## \[$declared\]" "$ROOT/CHANGELOG.md"; then
        printf 'FAIL: CHANGELOG.md has no released section for %s\n' "$declared" >&2
        status=1
    else
        printf 'ok  CHANGELOG.md\n'
    fi
    return "$status"
}

# Role: Run the complete dependency-free project test suite.
check_tests() {
    section 'Tests'
    "$ROOT/tests/run.sh"
}

# Role: Statically verify systemd units, creating only a temporary expected ExecStart symlink if needed.
check_systemd_units() {
    section 'systemd units'
    if ! command -v systemd-analyze >/dev/null 2>&1; then
        printf 'skip: systemd-analyze is not installed\n'
        return 0
    fi
    local expected="$HOME/.local/bin/keepalive" created=0
    mkdir -p "$HOME/.local/bin"
    if [[ ! -e $expected && ! -L $expected ]]; then
        ln -s "$ROOT/keepalive" "$expected"
        created=1
    fi
    # Ensure the temporary verification symlink is removed even if verification fails.
    if ! SYSTEMD_COLORS=0 TERM=dumb systemd-analyze verify "$ROOT/systemd/keepalive.socket" "$ROOT/systemd/keepalive.service"; then
        ((created == 0)) || rm -f -- "$expected"
        return 1
    fi
    ((created == 0)) || rm -f -- "$expected"
    printf 'ok  keepalive.socket / keepalive.service\n'
}

# Role: Execute all validation stages and report an explicit final success marker.
main() {
    check_syntax
    check_shellcheck
    check_version
    check_tests
    check_systemd_units
    section 'Result'
    printf 'ALL VALIDATION CHECKS PASSED\n'
}

main "$@"
