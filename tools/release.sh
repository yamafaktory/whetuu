#!/usr/bin/env bash
#
# Cuts a release end to end. Invoked by `zig build publish -- vX.Y.Z`:
#
#   1. checks the tree, the branch and the tag before touching anything
#   2. bumps build.zig.zon and commits it (skipped when already correct)
#   3. pushes main
#   4. waits for CI to pass on that exact commit
#   5. tags and pushes the tag, triggering .github/workflows/release.yml
#
# Steps 1 and 2 are ordered so every check that can fail cheaply runs before the
# first push. Once step 3 has run the bump commit is public, so a later failure
# leaves main one commit ahead — recoverable by re-running, never by force-push.

set -euo pipefail

readonly version=${1:-}
readonly branch=main
readonly poll_seconds=30
readonly ci_timeout_seconds=1200

# Tests set this to skip the CI wait; a real release never should.
readonly skip_ci=${WHETUU_PUBLISH_SKIP_CI:-}

die() {
    printf 'publish: %s\n' "$1" >&2
    exit 1
}

say() {
    printf 'publish: %s\n' "$1"
}

[ -n "$version" ] || die "no version given; use: zig build publish -- vX.Y.Z"
[ "$version" != dev ] || die "no version given; use: zig build publish -- vX.Y.Z"

if ! [[ $version =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.]+)?$ ]]; then
    die "version must look like v1.2.3 or v1.2.3-rc.1, got '$version'"
fi

command -v git >/dev/null 2>&1 || die "git not found on PATH"
root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$root"

[ -z "$(git status --porcelain)" ] || die "working tree is dirty; commit or stash first"

current_branch=$(git rev-parse --abbrev-ref HEAD)
[ "$current_branch" = "$branch" ] || die "on branch '$current_branch'; releases are cut from '$branch'"

git fetch --quiet origin "$branch"

# Starting level with the remote keeps the bump the only commit this adds.
[ "$(git rev-parse HEAD)" = "$(git rev-parse "origin/$branch")" ] ||
    die "local $branch and origin/$branch differ; push or pull first"

if git rev-parse -q --verify "refs/tags/$version" >/dev/null 2>&1; then
    die "tag $version already exists locally"
fi

if git ls-remote --exit-code --tags origin "refs/tags/$version" >/dev/null 2>&1; then
    die "tag $version already exists on origin"
fi

slug=$(git remote get-url origin | sed -E 's#^(git@github\.com:|ssh://git@github\.com/|https://github\.com/)##; s#\.git$##')
if [ -z "$skip_ci" ] && ! [[ $slug =~ ^[^/]+/[^/]+$ ]]; then
    die "origin does not look like a GitHub repository; cannot verify CI"
fi

# ---------------------------------------------------------------- bump + push

if bash tools/bump.sh "$version" | grep -q '\->'; then
    git add build.zig.zon
    git commit --quiet -m "Release $version"
    say "committed the build.zig.zon bump"
else
    say "build.zig.zon already at ${version#v}"
fi

if [ "$(git rev-parse HEAD)" != "$(git rev-parse "origin/$branch")" ]; then
    say "pushing $branch"
    git push --quiet origin "$branch"
fi

sha=$(git rev-parse HEAD)
readonly sha

# ------------------------------------------------------------------- wait CI

# Prints one of:
#   "<status> <conclusion>"  a run exists
#   "pending"                the run has not been created yet
#   "error <reason>"         the API could not be reached or read
#
# The pending/error split matters: treating an API failure as "not started yet"
# would silently burn the whole timeout and then blame CI.
ci_status() {
    local response body http
    response=$(curl -s -w '\n%{http_code}' --max-time 20 \
        "https://api.github.com/repos/$slug/actions/runs?head_sha=$sha&per_page=10" 2>/dev/null) ||
        {
            printf 'error unreachable\n'
            return
        }

    http=${response##*$'\n'}
    body=${response%$'\n'*}

    case "$http" in
        200) ;;
        403 | 429) printf 'error rate-limited (unauthenticated GitHub API allows 60 requests/hour)\n' && return ;;
        *) printf 'error HTTP %s\n' "$http" && return ;;
    esac

    printf '%s' "$body" | python3 -c '
import sys, json
try:
    runs = json.load(sys.stdin).get("workflow_runs", [])
except Exception:
    print("error unreadable response")
    sys.exit(0)
for r in runs:
    if r.get("name") == "CI":
        print(r.get("status"), r.get("conclusion"))
        break
else:
    print("pending")
'
}

wait_for_ci() {
    command -v curl >/dev/null 2>&1 || die "curl not found on PATH; needed to check CI"
    command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH; needed to check CI"

    local deadline=$((SECONDS + ci_timeout_seconds))
    local announced=''
    local errors=0

    while [ "$SECONDS" -lt "$deadline" ]; do
        local line status conclusion
        line=$(ci_status)
        status=${line%% *}
        conclusion=${line##* }

        # Tolerate a blip, but never mistake a persistent API failure for a
        # slow CI run.
        if [ "$status" = error ]; then
            errors=$((errors + 1))
            [ "$errors" -lt 3 ] || die "cannot read CI status: ${line#error }"
            sleep "$poll_seconds"
            continue
        fi
        errors=0

        if [ "$status" = completed ]; then
            [ "$conclusion" = success ] || die "CI concluded '$conclusion' for ${sha:0:7}; not tagging"
            say "CI passed"
            return 0
        fi

        if [ -z "$announced" ]; then
            say "waiting for CI on ${sha:0:7} (up to $((ci_timeout_seconds / 60))m)"
            announced=1
        fi

        sleep "$poll_seconds"
    done

    die "timed out waiting for CI on ${sha:0:7}; re-run once it finishes"
}

if [ -n "$skip_ci" ]; then
    say "skipping the CI wait (WHETUU_PUBLISH_SKIP_CI set)"
else
    wait_for_ci
fi

# ----------------------------------------------------------------------- tag

say "tagging $version at ${sha:0:7}"
git tag -a "$version" -m "$version"

if ! git push --quiet origin "$version"; then
    git tag -d "$version" >/dev/null
    die "pushing the tag failed; removed the local tag again"
fi

say "pushed $version — the release workflow is building it now"
