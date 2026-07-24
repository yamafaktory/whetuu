#!/usr/bin/env bash
#
# Regenerates CHANGELOG.md from git history. Invoked by `zig build changelog`,
# and by tools/release.sh so a release never depends on remembering to run it.
#
#   tools/changelog.sh              commits since the last tag go under Unreleased
#   tools/changelog.sh v0.1.6       they go under v0.1.6, dated today
#
# The file is derived, never edited by hand. Commit subjects are the source, so
# a subject is what a user reads: write it for them, in the imperative, and the
# entry needs no further work. Anything genuinely internal belongs in the body
# of the commit message, which never appears here, or in changelog-skip.txt.
#
# Sections come from the leading verb. "Add ..." is an addition, "Fix ..." a
# fix, "Remove ..." a removal, everything else a change. That is a heuristic,
# not a contract: a miscategorised line is a wrong heading, never a lost entry.

set -euo pipefail

readonly pending=${1:-}
readonly skip_file=tools/changelog-skip.txt

die() {
    printf 'changelog: %s\n' "$1" >&2
    exit 1
}

if [ -n "$pending" ] && ! [[ $pending =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    die "version must look like v1.2.3 or v1.2.3-rc.1, got '$pending'"
fi

command -v git >/dev/null 2>&1 || die "git not found on PATH"
root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$root"

# Commits that should never reach a user, listed by full SHA in
# changelog-skip.txt. Abbreviated to match `git log --format=%h` output.
declare -A skip=()
if [ -f "$skip_file" ]; then
    while read -r sha _; do
        case $sha in '' | '#'*) continue ;; esac
        skip[$(git rev-parse --short "$sha" 2>/dev/null || printf '%s' "$sha")]=1
    done <"$skip_file"
fi

# Oldest to newest, so the file can be written newest first.
mapfile -t tags < <(git tag -l --sort=v:refname)

# Every subject in a range, minus merges, skipped commits, and the bump commit
# a release adds. `Release vX.Y.Z` is bookkeeping: it says a version happened,
# which is the heading it sits under.
subjects() {
    local sha subject
    while IFS=$'\t' read -r sha subject; do
        [ -n "${skip[$sha]-}" ] && continue
        # Subjects have picked up stray leading space over the years, and a
        # bullet inherits whatever it is given.
        subject=${subject#"${subject%%[![:space:]]*}"}
        subject=${subject%"${subject##*[![:space:]]}"}
        [ -n "$subject" ] || continue
        case $subject in 'Release v'[0-9]*) continue ;; esac
        printf '%s\n' "$subject"
    done < <(git log --no-merges --reverse --format='%h%x09%s' "$1" 2>/dev/null)
}

# Prints the four sections for a range, omitting any that would be empty.
body() {
    local range=$1 line
    local -a added=() fixed=() removed=() changed=()

    while IFS= read -r line; do
        case $line in
            Add* | Introduce*) added+=("$line") ;;
            Fix* | Correct* | Prevent* | Stop*) fixed+=("$line") ;;
            Remove* | Drop* | Delete*) removed+=("$line") ;;
            *) changed+=("$line") ;;
        esac
    done < <(subjects "$range")

    local name
    for name in Added Changed Fixed Removed; do
        # A nameref keeps the order above independent of which bucket each line
        # landed in. Indirect expansion cannot do this: on an empty array it
        # yields one empty string, which prints as a bullet with nothing on it.
        local -n entries="${name,,}"
        [ ${#entries[@]} -gt 0 ] || continue
        printf '### %s\n\n' "$name"
        printf -- '- %s\n' "${entries[@]}"
        printf '\n'
    done
}

tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT

cat >"$tmp" <<'EOF'
# Changelog

Every released version, newest first. Generated from the commit history by
`zig build changelog`, so it is never edited by hand.

EOF

# The range above the newest tag: a pending release when publishing, otherwise
# whatever has landed since. Skipped entirely when there is nothing there.
readonly newest=${tags[${#tags[@]} - 1]-}
readonly head_range=${newest:+$newest..HEAD}
if [ -n "$(subjects "${head_range:-HEAD}")" ]; then
    if [ -n "$pending" ]; then
        printf '## %s — %s\n\n' "$pending" "$(date +%Y-%m-%d)" >>"$tmp"
    else
        printf '## Unreleased\n\n' >>"$tmp"
    fi
    body "${head_range:-HEAD}" >>"$tmp"
fi

# Newest tag first, each against the tag before it.
for ((i = ${#tags[@]} - 1; i >= 0; i--)); do
    tag=${tags[i]}
    if [ "$i" -gt 0 ]; then
        range="${tags[i - 1]}..$tag"
    else
        range=$tag
    fi

    printf '## %s — %s\n\n' "$tag" "$(git log -1 --format=%ad --date=short "$tag")" >>"$tmp"
    body "$range" >>"$tmp"
done

# Trailing blank lines accumulate from the per-section spacing.
printf '%s\n' "$(cat "$tmp")" >CHANGELOG.md

if [ -n "$pending" ]; then
    printf 'changelog: CHANGELOG.md regenerated with %s\n' "$pending"
else
    printf 'changelog: CHANGELOG.md regenerated\n'
fi
