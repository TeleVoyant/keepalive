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
        printf 'ok  %s\n' "${file#"$ROOT"/}"
    done < <(find "$ROOT" -type f \( -name '*.sh' -o -name keepalive \) -print0 | sort -z)
}

# Role: Run ShellCheck when installed while remaining usable on dependency-minimal hosts.
check_shellcheck() {
    section 'ShellCheck'
    # Findings were cleared for 1.0.0 and CI gates on this. It still self-skips when
    # ShellCheck is absent, so the suite stays runnable on a dependency-minimal host.
    # The codes disabled project-wide, and why, are documented in .shellcheckrc.
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

# Role: Test whether CHANGELOG.md has the dated release heading for exactly this version.
# Literal, not a regex (the dots in X.Y.Z would match any character, so "[1x1x0]" would
# pass), and complete: "## [X.Y.Z] - YYYY-MM-DD", never an undated or annotated heading.
changelog_has_release() {
    awk -v heading="## [$1] - " '
        index($0, heading) == 1 && length($0) == length(heading) + 10 &&
            substr($0, length(heading) + 1) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
            found=1; exit
        }
        END { exit !found }
    ' "$2"
}

# Role: Test whether CHANGELOG.md has a section heading for exactly this version.
# Literal, not a regex: the dots in X.Y.Z would match any character ("[1x1x0]").
changelog_has_version() {
    awk -v heading="## [$1]" '
        index($0, heading) == 1 &&
            (length($0) == length(heading) || substr($0, length(heading) + 1, 1) ~ /[[:space:]]/) {
            found=1; exit
        }
        END { exit !found }
    ' "$2"
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
    for file in README.md VALIDATION.md docs/VALIDATION.md .agents/README.md; do
        if [[ ! -f $ROOT/$file ]]; then
            [[ $file == .agents/README.md ]] || { printf 'FAIL: %s is missing\n' "$file" >&2; status=1; continue; }
            printf 'skip  %s (not included in installed tree)\n' "$file"
            continue
        fi
        found=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/$file" | head -1)
        if [[ $found != "$declared" ]]; then
            printf 'FAIL: %s declares %s, expected %s\n' "$file" "${found:-none}" "$declared" >&2
            status=1
            continue
        fi
        printf 'ok  %s\n' "$file"
    done
    # A release tag is cut from CHANGELOG.md, so an unreleased version there is a mistake.
    if ! changelog_has_release "$declared" "$ROOT/CHANGELOG.md"; then
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
    local expected="$HOME/.local/bin/keepalive" created=0 systemd_version
    systemd_version=$(systemd-analyze --version | awk 'NR == 1 { print $2 }')
    if [[ $systemd_version =~ ^[0-9]+$ ]] && ((systemd_version < 235)); then
        printf 'FAIL: systemd-analyze %s is older than the supported systemd 235 floor\n' \
            "$systemd_version" >&2
        return 1
    fi
    printf 'ok  systemd-analyze %s (supported floor: 235)\n' "${systemd_version:-unknown}"
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
