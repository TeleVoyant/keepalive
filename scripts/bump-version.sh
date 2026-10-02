#!/usr/bin/env bash
# Update the release version and open the matching changelog section.
set -Eeuo pipefail

ROOT=$(cd "${BASH_SOURCE[0]%/*}/.." && pwd)
BUMP_TMP=''

# Role: Remove an interrupted temporary document without touching the source tree.
cleanup() {
    [[ -z ${BUMP_TMP:-} ]] || rm -f -- "$BUMP_TMP"
}

# Role: Stop before changing files when the requested version is not a simple X.Y.Z value.
fatal() {
    printf 'bump-version: %s\n' "$*" >&2
    exit 1
}

# Role: Update the executable and the documented current-version lines consistently.
update_version_files() {
    local version=$1 today=$2 declared agents_tmp changed=0
    declared=$(sed -n "s/^KEEPALIVE_VERSION='\([^']*\)'$/\1/p" "$ROOT/keepalive")
    [[ $declared =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fatal 'keepalive does not declare a valid KEEPALIVE_VERSION'
    [[ $declared == "$version" ]] || changed=1

    sed -i -E "s/^KEEPALIVE_VERSION='[0-9]+\.[0-9]+\.[0-9]+'$/KEEPALIVE_VERSION='$version'/" \
        "$ROOT/keepalive"
    sed -i -E "s/^(Version: \*\*)[0-9]+\.[0-9]+\.[0-9]+(\*\*.*)$/\1$version\2/" \
        "$ROOT/README.md"
    sed -i -E "s/^Version: [0-9]+\.[0-9]+\.[0-9]+$/Version: $version/" \
        "$ROOT/VALIDATION.md" "$ROOT/docs/VALIDATION.md"

    agents_tmp=$(mktemp "$ROOT/.agents/README.md.tmp.XXXXXX")
    BUMP_TMP=$agents_tmp
    # mktemp creates 0600; the replacement must keep the document's own mode (0644), or
    # other users - the non-root CI lane, an installer run as another account - cannot read it.
    chmod --reference="$ROOT/.agents/README.md" -- "$agents_tmp"
    awk -v version="$version" -v today="$today" -v changed="$changed" '
        /^- Reviewed baseline commit:/ { sub(/[0-9]+\.[0-9]+\.[0-9]+/, version) }
        /^- Release:/ {
            gsub(/[0-9]+\.[0-9]+\.[0-9]+/, version)
            if (changed) sub(/released [0-9-]+/, "released " today)
        }
        /^- Product version:/ { gsub(/[0-9]+\.[0-9]+\.[0-9]+/, version) }
        /^- Contents of / { sub(/[0-9]+\.[0-9]+\.[0-9]+/, version) }
        /^  daemon runs / { sub(/[0-9]+\.[0-9]+\.[0-9]+/, version) }
        { print }
    ' "$ROOT/.agents/README.md" >"$agents_tmp"
    mv -- "$agents_tmp" "$ROOT/.agents/README.md"
    BUMP_TMP=''

    [[ $(sed -n "s/^KEEPALIVE_VERSION='\([^']*\)'$/\1/p" "$ROOT/keepalive") == "$version" ]] \
        || fatal 'failed to update keepalive'
    [[ $(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$ROOT/.agents/README.md" | head -1) == "$version" ]] \
        || fatal 'failed to update the agent version line'
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

# Role: Rename an Unreleased changelog section or insert a new dated release section.
update_changelog() {
    local version=$1 today=$2 file="$ROOT/CHANGELOG.md" reference tmp
    reference="[$version]: https://github.com/TeleVoyant/keepalive/releases/tag/v$version"

    if ! changelog_has_version "$version" "$file"; then
        tmp=$(mktemp "$ROOT/CHANGELOG.md.tmp.XXXXXX")
        BUMP_TMP=$tmp
        chmod --reference="$file" -- "$tmp"
        awk -v version="$version" -v today="$today" '
            BEGIN { inserted=0; moved=0 }
            /^## \[Unreleased\]([[:space:]]|$)/ {
                print "## [" version "] - " today
                print ""
                inserted=1
                moved=1
                next
            }
            !inserted && /^## \[/ {
                print "## [" version "] - " today
                print ""
                inserted=1
            }
            moved && /^\[Unreleased\]:[[:space:]]*/ { next }
            { print }
            END {
                if (!inserted) {
                    print ""
                    print "## [" version "] - " today
                }
            }
        ' "$file" >"$tmp"
        mv -- "$tmp" "$file"
        BUMP_TMP=''
    fi

    if ! grep -Fqx -- "$reference" "$file"; then
        tmp=$(mktemp "$ROOT/CHANGELOG.md.tmp.XXXXXX")
        BUMP_TMP=$tmp
        chmod --reference="$file" -- "$tmp"
        cat "$file" >"$tmp"
        printf '\n%s\n' "$reference" >>"$tmp"
        mv -- "$tmp" "$file"
        BUMP_TMP=''
    fi
}

trap cleanup EXIT

# Role: Parse the requested version, then perform the complete mechanical release bump.
main() {
    local version today
    [[ $# == 1 ]] || fatal "usage: $0 X.Y.Z"
    version=$1
    [[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
        || fatal 'version must match X.Y.Z'
    today=$(date +%F)
    # Refuse before touching anything: an existing [X.Y.Z] heading is reused, not
    # duplicated, so an undated one would otherwise fail only after the version moved.
    if changelog_has_version "$version" "$ROOT/CHANGELOG.md" \
        && ! changelog_has_release "$version" "$ROOT/CHANGELOG.md"; then
        fatal "CHANGELOG.md has a [$version] heading that is not '## [$version] - YYYY-MM-DD'"
    fi
    update_version_files "$version" "$today"
    update_changelog "$version" "$today"
    # An existing heading is reused rather than duplicated; it must be the dated form
    # that dev-check and the release workflow accept.
    changelog_has_release "$version" "$ROOT/CHANGELOG.md" \
        || fatal "CHANGELOG.md has a [$version] heading that is not '## [$version] - YYYY-MM-DD'"
    printf 'updated Keep Alive Manager to %s (%s)\n' "$version" "$today"
}

main "$@"
