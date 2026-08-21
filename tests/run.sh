#!/usr/bin/env bash
# Dependency-free aggregate test runner used locally and in CI.
set -Eeuo pipefail
ROOT=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
failed=0 total=0

# Role: Run every test_*.sh file in isolation and return non-zero if any test fails.
main() {
    local file
    for file in "$ROOT"/test_*.sh; do
        [[ $file == *testlib.sh ]] && continue
        ((total += 1))
        printf '\n==> %s\n' "${file##*/}"
        if bash "$file"; then
            :
        else
            ((failed += 1))
        fi
    done
    printf '\n==> test files: %d, failed: %d\n' "$total" "$failed"
    ((failed == 0))
}

main "$@"
