#!/usr/bin/env bash
#
# End to end check of the command that talks to GitHub, `whetuu upgrade`, in
# both its forms — installing, and `--check` — against the real releases. Run by
# CI next to `zig build test`.
#
# The unit tests cover unpacking a release archive, swapping the binary on disk,
# reading and writing the release cache, and when the status line shows a
# notice — all with no network. This covers the half they cannot reach:
# resolving the newest release through the GitHub API, downloading it, checking
# it against SHA256SUMS, a binary replacing itself while it runs, and the status
# line starting the daily check on its own.
#
# It builds whetuu stamped with a version below every release, so the upgrade
# always has somewhere to go, and points it at a copy in a temporary directory.
# Nothing outside that directory is touched.
#
# Needs the network. When GitHub cannot be reached, or answers with a rate
# limit, the check skips: an unreachable GitHub is not a broken whetuu.

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
# Below every release, so `upgrade` always has a newer one to find.
readonly old=v0.0.1
failures=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

check() {
    local name=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$name" "$expected" "$actual"
    failures=$((failures + 1))
}

# The output is printed in full above, so a miss names what it looked for and
# leaves the haystack there.
contains() {
    local name=$1 needle=$2 haystack=$3
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s\n       looked for: %s\n' "$name" "$needle"
    failures=$((failures + 1))
}

# whetuu colours what it prints, so every match runs against the text without
# the escapes rather than against the bytes.
plain() {
    printf '%s' "$1" | sed 's/\x1b\[[0-9;]*m//g'
}

printf 'building whetuu %s\n' "$old"
(cd "$root" && zig build --release=fast -p "$work/build" -Dversion="$old")

mkdir -p "$work/bin"
cp "$work/build/bin/whetuu" "$work/bin/whetuu"

printf 'upgrading it\n\n'
status=0
output=$("$work/bin/whetuu" upgrade 2>&1) || status=$?
printf '%s\n\n' "$output"
text=$(plain "$output")

# A network that is down, or an API that is rate limiting this runner, says
# nothing about the code under test.
if [ "$status" -ne 0 ] && printf '%s' "$text" | grep -qE 'could not fetch|could not reach|returned 4[0-9][0-9]'; then
    printf 'skipped: GitHub is not reachable from here\n'
    exit 0
fi

check "the upgrade succeeds" 0 "$status"
contains "it says what it downloaded" "whetuu-" "$text"
contains "it verifies the download" "sha256 matches SHA256SUMS" "$text"
contains "it installs over the running binary" "$work/bin/whetuu" "$text"

installed=$("$work/bin/whetuu" --version)
if [ "$installed" = "$old" ]; then
    check "the binary is replaced" "a newer version" "still $old"
else
    printf 'ok   the binary is replaced, now %s\n' "$installed"
fi

# The changelog of the release it landed on, which is the second half of what
# the command promises. Its entries are the indented dashes.
contains "it prints the release it landed on" "$installed" "$text"
contains "it prints what changed" "  - " "$text"

# What it installed is the release GitHub calls latest, not merely something
# newer than the stamp. Skipped where there is no curl to ask with.
if command -v curl >/dev/null 2>&1; then
    # `|| true` because an API that will not answer this second is the skip
    # above, not a failing check.
    latest=$(curl --proto '=https' --tlsv1.2 -fsSL https://api.github.com/repos/yamafaktory/whetuu/releases/latest |
        sed -n 's/.*"tag_name" *: *"\([^"]*\)".*/\1/p' | head -n 1) || true
    if [ -n "$latest" ]; then
        check "it installs the newest release" "$latest" "$installed"
    fi
fi

# `whetuu upgrade --check` is what feeds the status line notice: it asks the
# API, prints what is waiting, and writes the answer down. The build stamped
# $old is used again here, because the release it just installed predates the
# flag.
printf '\nchecking for a release\n\n'
cache="$work/cache"
status=0
output=$(XDG_CACHE_HOME="$cache" "$work/build/bin/whetuu" upgrade --check 2>&1) || status=$?
printf '%s\n\n' "$output"

check "the check succeeds" 0 "$status"
contains "it names the release it found" "$installed" "$(plain "$output")"
contains "it says how to install it" "whetuu upgrade" "$(plain "$output")"
contains "it prints what changed" "  - " "$(plain "$output")"

# It is a dry run, so the binary it was run from is the one still there.
check "it installs nothing" "$old" "$("$work/build/bin/whetuu" --version)"

if [ -f "$cache/whetuu/release" ]; then
    printf 'ok   it writes the release cache\n'
    check "the cache holds the newest tag" "$installed" "$(cut -f1 "$cache/whetuu/release")"
else
    check "it writes the release cache" "$cache/whetuu/release" "no file"
fi

# With that cache warm, the status line says so. This is the notice itself,
# rendered by the same code a shell calls on every prompt.
line=$(plain "$(XDG_CACHE_HOME="$cache" "$work/build/bin/whetuu" render --shell fish --status 0 --width 200)")
contains "the status line shows the new version" "$installed" "$line"

# And a render with nothing cached starts the check on its own, detached, while
# printing a status line that says nothing about it. The file appearing is the
# whole proof: the child ran, reached GitHub and wrote, with its output on
# /dev/null throughout.
printf '\nrendering with an empty cache\n'
fresh="$work/fresh"
line=$(plain "$(XDG_CACHE_HOME="$fresh" "$work/build/bin/whetuu" render --shell fish --status 0 --width 200)")
if printf '%s' "$line" | grep -qF -- "$installed"; then
    check "the first render says nothing about a release" "no mention of $installed" "$line"
else
    printf 'ok   the first render says nothing about a release\n'
fi

# The render stamps the time before it starts anything, so the file is there at
# once holding no tag. That stamp is what stops a check that never finishes, or
# a cache directory that cannot be written, from starting one per prompt.
if [ -f "$fresh/whetuu/release" ]; then
    check "the render stamps the cache before spawning" "" "$(cut -f1 "$fresh/whetuu/release")"
else
    check "the render stamps the cache before spawning" "a stamped cache" "no file"
fi

# Then the child fills the tag in, once its round trip to GitHub comes back.
waited=0
while [ -z "$(cut -f1 "$fresh/whetuu/release" 2>/dev/null)" ] && [ "$waited" -lt 15 ]; do
    sleep 1
    waited=$((waited + 1))
done
found=$(cut -f1 "$fresh/whetuu/release" 2>/dev/null)
if [ -n "$found" ]; then
    printf 'ok   the render started the check by itself, answered after %ss\n' "$waited"
    check "the check it started found the newest tag" "$installed" "$found"
else
    check "the render started the check by itself" "a tag" "nothing after ${waited}s"
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall release checks passed\n'
