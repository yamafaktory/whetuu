#!/usr/bin/env bash
#
# Tags the current commit and pushes the tag, which is what triggers
# .github/workflows/release.yml. Invoked by `zig build publish -Dversion=vX.Y.Z`.
#
# Every check below aborts before anything is pushed, so a failed run leaves no
# tag behind locally or on the remote.

set -euo pipefail

readonly version=${1:-}
readonly branch=main

die() {
    printf 'publish: %s\n' "$1" >&2
    exit 1
}

[ -n "$version" ] || die "no version given; use: zig build publish -Dversion=vX.Y.Z"
[ "$version" != dev ] || die "-Dversion=vX.Y.Z is required (got the 'dev' default)"

if ! [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    die "version must look like v1.2.3 or v1.2.3-rc.1, got '$version'"
fi

command -v git >/dev/null 2>&1 || die "git not found on PATH"
git rev-parse --git-dir >/dev/null 2>&1 || die "not inside a git repository"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty; commit or stash first"

current=$(git rev-parse --abbrev-ref HEAD)
[ "$current" = "$branch" ] || die "on branch '$current'; releases are cut from '$branch'"

git fetch --quiet origin "$branch"

# A tag is only meaningful if the commit it names is already on the remote —
# the workflow checks out the tag, not your working tree.
[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$branch")" ] ||
    die "local $branch and origin/$branch differ; push or pull first"

if git rev-parse -q --verify "refs/tags/$version" >/dev/null 2>&1; then
    die "tag $version already exists locally"
fi

if git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null 2>&1; then
    die "tag $version already exists on origin"
fi

printf 'publish: tagging %s at %s\n' "$version" "$(git rev-parse --short HEAD)"
git tag -a "$version" -m "$version"

if ! git push --quiet origin "$version"; then
    git tag -d "$version" >/dev/null
    die "pushing the tag failed; removed the local tag again"
fi

printf 'publish: pushed %s — the release workflow is building it now\n' "$version"

if command -v gh >/dev/null 2>&1; then
    printf 'publish: follow it with:  gh run watch\n'
    printf 'publish: then check:      gh release view %s\n' "$version"
fi
