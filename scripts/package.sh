#!/usr/bin/env bash
# Create a clean zip archive and SHA-256 digest for release handoff.
set -Eeuo pipefail
ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
PARENT=${ROOT%/*}
NAME=${ROOT##*/}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${1:-"$PARENT/${NAME}-${STAMP}.zip"}
# Resolve a relative output path against the caller's directory: the archive is written
# from inside $PARENT, where a relative name would land somewhere else.
[[ $OUT == /* ]] || OUT="$PWD/$OUT"

# Role: Package the public project allowlist, verify its required files, and print its digest.
main() {
    command -v zip >/dev/null 2>&1 || { printf 'package: zip command is required\n' >&2; exit 1; }
    command -v unzip >/dev/null 2>&1 || { printf 'package: unzip command is required to verify the archive\n' >&2; exit 1; }
    command -v sha256sum >/dev/null 2>&1 || { printf 'package: sha256sum is required\n' >&2; exit 1; }
    local -a allowlist=(
        CHANGELOG.md CONTRIBUTING.md LICENSE README.md VALIDATION.md
        docs keepalive lib scripts systemd tests
    )
    local -a required=(CHANGELOG.md CONTRIBUTING.md LICENSE README.md VALIDATION.md)
    local -a zip_paths=()
    local entry archive_entries
    for entry in "${allowlist[@]}"; do zip_paths+=("$NAME/$entry"); done
    rm -f -- "$OUT"
    (
        cd "$PARENT"
        zip -qr "$OUT" "${zip_paths[@]}" \
            -x "$NAME/*.zip" "$NAME/**/__pycache__/*" "$NAME/**/.DS_Store"
    )
    archive_entries=$(unzip -Z1 -- "$OUT") || {
        printf 'package: could not inspect %s\n' "$OUT" >&2
        exit 1
    }
    if grep -Eq '(^|/)\.agents(/|$)|(^|/)\.git(/|$)' <<<"$archive_entries"; then
        printf 'package: archive contains private VCS/agent metadata\n' >&2
        exit 1
    fi
    for entry in "${required[@]}"; do
        grep -Fxq -- "$NAME/$entry" <<<"$archive_entries" || {
            printf 'package: archive is missing required file %s\n' "$entry" >&2
            exit 1
        }
    done
    printf '%s\n' "$OUT"
    sha256sum "$OUT"
}

main "$@"
