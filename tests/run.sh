#!/usr/bin/env bash
# Dependency-free aggregate test runner used locally and in CI.
set -Eeuo pipefail
ROOT=$(cd "${BASH_SOURCE[0]%/*}" && pwd)
failed=0 total=0 assertions=0 missing_summary=0 RUN_TMP=''

# Role: Remove captured test output after the aggregate run exits.
cleanup() {
    [[ -z ${RUN_TMP:-} ]] || rm -rf -- "$RUN_TMP"
}

# Role: Run every test_*.sh file in isolation and return non-zero if any test fails.
main() {
    local file output rc summary passed
    RUN_TMP=$(mktemp -d)
    output=$RUN_TMP
    trap cleanup EXIT
    for file in "$ROOT"/test_*.sh; do
        [[ $file == *testlib.sh ]] && continue
        ((total += 1))
        printf '\n==> %s\n' "${file##*/}"
        rc=0
        bash "$file" >"$output/${file##*/}" 2>&1 || rc=$?
        cat "$output/${file##*/}"
        if ((rc != 0)); then
            ((failed += 1))
        fi
        summary=$(grep -E '^# ([0-9]+ assertions passed|[0-9]+/[0-9]+ assertions failed)$' \
            "$output/${file##*/}" || true)
        if [[ -z $summary ]]; then
            printf 'not ok - %s printed no assertion summary\n' "${file##*/}"
            ((missing_summary += 1))
            continue
        fi
        # The summary is the second source of truth: a file that reports failures, or
        # prints more than one summary, has failed even if it happened to exit 0. Only a
        # single passing summary is counted, so duplicates can never reach arithmetic.
        if [[ $summary == *$'\n'* || $summary == *'assertions failed'* ]]; then
            if ((rc == 0)); then
                printf 'not ok - %s reported a failing or conflicting summary but exited 0\n' "${file##*/}"
                ((failed += 1))
            fi
            continue
        fi
        passed=${summary#'# '}
        passed=${passed%' assertions passed'}
        [[ $passed =~ ^[0-9]+$ ]] && assertions=$((assertions + passed))
    done
    printf '\n==> test files: %d, assertions: %d, failed: %d\n' \
        "$total" "$assertions" "$failed"
    if ((missing_summary > 0)); then
        printf '==> files missing assertion summaries: %d\n' "$missing_summary"
    fi
    ((failed == 0 && missing_summary == 0))
}

main "$@"
