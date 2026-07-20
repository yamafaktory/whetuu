#!/usr/bin/env bash
#
# Rewrites the .version field in build.zig.zon. Invoked by
# `zig build bump -- vX.Y.Z`.
#
# Only the file is touched — committing it is left to you, so the bump lands in
# a reviewable commit that CI runs on before `zig build publish` tags it.

set -euo pipefail

readonly version=${1:-}

die() {
    printf 'bump: %s\n' "$1" >&2
    exit 1
}

[ -n "$version" ] || die "no version given; use: zig build bump -- vX.Y.Z"

if ! [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    die "version must look like v1.2.3 or v1.2.3-rc.1, got '$version'"
fi

command -v git >/dev/null 2>&1 || die "git not found on PATH"
root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$root"

[ -f build.zig.zon ] || die "no build.zig.zon at $root"

# build.zig.zon takes a bare semver; the leading v belongs to the git tag only.
readonly semver=${version#v}

current=$(sed -n 's/^[[:space:]]*\.version[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' build.zig.zon)
[ -n "$current" ] || die "could not find a .version field in build.zig.zon"

if [ "$current" = "$semver" ]; then
    printf 'bump: build.zig.zon already at %s\n' "$semver"
    exit 0
fi

# Rewritten via a temp file rather than sed -i, whose flags differ on BSD/macOS.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
awk -v semver="$semver" '
    !done && /^[[:space:]]*\.version[[:space:]]*=/ {
        sub(/"[^"]*"/, "\"" semver "\"")
        done = 1
    }
    { print }
' build.zig.zon >"$tmp"
cat "$tmp" >build.zig.zon

printf 'bump: build.zig.zon %s -> %s\n' "$current" "$semver"
printf 'bump: commit it, let CI pass, then: zig build publish -- %s\n' "$version"
