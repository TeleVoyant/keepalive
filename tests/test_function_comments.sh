#!/usr/bin/env bash
set -Eeuo pipefail
source "${BASH_SOURCE[0]%/*}/testlib.sh"
test_env_setup

# This test intentionally checks project convention: each function must be immediately
# preceded by a '# Role:' maintenance comment (blank lines are allowed before it).
missing=0
while IFS= read -r file; do
    while IFS=: read -r lineno definition; do
        prev=$((lineno - 1))
        found=0
        # Walk the contiguous comment block immediately above the function.
        while ((prev > 0)); do
            line=$(sed -n "${prev}p" "$file")
            if [[ -z ${line//[[:space:]]/} ]]; then
                ((prev -= 1))
                continue
            fi
            [[ $line == '#'* ]] || break
            [[ $line == '# Role:'* ]] && { found=1; break; }
            ((prev -= 1))
        done
        if ((found == 0)); then
            printf 'missing Role comment: %s:%s %s\n' "$file" "$lineno" "$definition"
            ((missing += 1))
        fi
    done < <(grep -nE '^[A-Za-z_][A-Za-z0-9_]*\(\)[[:space:]]*\{' "$file" || true)
done < <(find "$TEST_ROOT" -type f \( -name '*.sh' -o -name keepalive \) ! -path '*/tests/test_function_comments.sh' | sort)

assert_eq 0 "$missing" 'every production/test helper function has an adjacent Role comment'
test_finish
