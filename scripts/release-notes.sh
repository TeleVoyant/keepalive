#!/usr/bin/env bash
# Print the CHANGELOG.md section body for one release, for the GitHub Release description.
set -Eeuo pipefail

# Role: Stop with a message on stderr.
fatal() {
    printf 'release-notes: %s\n' "$*" >&2
    exit 1
}

# Role: Print the body of the "## [VERSION] ..." section, or fail when it has no text.
# Only the complete dated heading "## [X.Y.Z] - YYYY-MM-DD" starts the section, matched
# literally (index, not a regex): the dots in a version are regex wildcards, so "[1x1x0]"
# would otherwise pass for "[1.1.0]". The heading itself is left out because the release
# title already names the version.
main() {
    local version=${1-} changelog=${2:-CHANGELOG.md} notes
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fatal "usage: release-notes.sh X.Y.Z [CHANGELOG.md]"
    [[ -f $changelog && -r $changelog ]] || fatal "cannot read $changelog"
    notes=$(awk -v heading="## [$version] - " '
        index($0, heading) == 1 && length($0) == length(heading) + 10 &&
            substr($0, length(heading) + 1) ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ {
            in_section=1; next
        }
        in_section && /^## \[/ { exit }
        in_section { print }
    ' "$changelog")
    # A heading followed directly by the next one leaves only blank lines.
    [[ $notes == *[![:space:]]* ]] || fatal "$changelog has no non-empty section for $version"
    printf '%s\n' "$notes"
}

main "$@"
