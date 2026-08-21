#!/usr/bin/env bash
# Create a clean zip archive and SHA-256 digest for release handoff.
set -Eeuo pipefail
ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
PARENT=${ROOT%/*}
NAME=${ROOT##*/}
STAMP=$(date +%Y%m%d-%H%M%S)
OUT=${1:-"$PARENT/${NAME}-${STAMP}.zip"}

# Role: Package the project without VCS/cache artifacts and print its SHA-256 checksum.
main() {
    command -v zip >/dev/null 2>&1 || { printf 'package: zip command is required\n' >&2; exit 1; }
    command -v sha256sum >/dev/null 2>&1 || { printf 'package: sha256sum is required\n' >&2; exit 1; }
    rm -f -- "$OUT"
    (
        cd "$PARENT"
        zip -qr "$OUT" "$NAME" -x "$NAME/.git/*" "$NAME/*.zip" "$NAME/**/__pycache__/*" "$NAME/**/.DS_Store"
    )
    printf '%s\n' "$OUT"
    sha256sum "$OUT"
}

main "$@"
