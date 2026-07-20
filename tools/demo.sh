#!/usr/bin/env bash
#
# Re-records docs/demo.cast and renders docs/demo.gif, the recording shown in
# the README. Invoked by `zig build demo`.
#
# The GIF has to carry the font: whetuu's prompt is Nerd Font glyphs end to end,
# and a viewer whose font lacks them sees tofu boxes instead of the prompt.

set -euo pipefail

readonly font=${WHETUU_DEMO_FONT:-MesloLGS Nerd Font Mono}
readonly font_size=${WHETUU_DEMO_FONT_SIZE:-16}

die() {
    printf 'demo: %s\n' "$1" >&2
    exit 1
}

command -v git >/dev/null 2>&1 || die "git not found on PATH"
root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$root"

command -v python3 >/dev/null 2>&1 || die "python3 not found on PATH"
command -v fish >/dev/null 2>&1 ||
    die "fish not found; the up-arrow picker binding ships only in the fish integration"

if ! command -v agg >/dev/null 2>&1; then
    die "agg not found; install it with: cargo install --git https://github.com/asciinema/agg"
fi

# A missing font renders every glyph as a box, which is worse than failing:
# the GIF still builds and only looks broken.
#
# The family list is collected first rather than piped into `grep -q`, which
# would exit early, SIGPIPE the upstream `tr`, and trip `pipefail` on a match.
if command -v fc-list >/dev/null 2>&1; then
    families=$(fc-list : family | tr ',' '\n')
    case $'\n'"$families"$'\n' in
        *$'\n'"$font"$'\n'*) ;;
        *) die "font '$font' not installed; set WHETUU_DEMO_FONT to a Nerd Font you have" ;;
    esac
fi

mkdir -p docs

printf 'demo: recording docs/demo.cast\n'
python3 tools/record-demo.py docs/demo.cast

printf 'demo: rendering docs/demo.gif with %s\n' "$font"
agg \
    --font-family "$font" \
    --font-size "$font_size" \
    --speed 1.3 \
    --idle-time-limit 1.5 \
    --last-frame-duration 3 \
    --theme asciinema \
    docs/demo.cast docs/demo.gif >/dev/null 2>&1

printf 'demo: docs/demo.gif is %s\n' "$(du -h docs/demo.gif | cut -f1)"
printf 'demo: check it before committing — pacing and colours are not verifiable from a diff\n'
