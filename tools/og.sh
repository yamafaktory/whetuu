#!/usr/bin/env bash
#
# Renders the two social images, both invoked by `zig build og`:
#
#   tools/og.html    -> docs/og.png     1200x630, what link previews show
#   tools/thumb.html -> docs/thumb.png  480x480, the square mark in listings
#
# The card is HTML so it shares the landing page's fonts, palette and star
# glyph. Drawing it a second way is how a card drifts from the page it
# represents.

set -euo pipefail

die() {
    printf 'og: %s\n' "$1" >&2
    exit 1
}

root=$(git rev-parse --show-toplevel 2>/dev/null) || die "not inside a git repository"
cd "$root"

for candidate in google-chrome-stable google-chrome chromium chromium-browser; do
    if command -v "$candidate" >/dev/null 2>&1; then
        chrome=$candidate
        break
    fi
done
[ -n "${chrome:-}" ] || die "need Chrome or Chromium to render the card"

# The page pulls IBM Plex from Google Fonts, so the render needs the network.
# --virtual-time-budget holds the screenshot until the fonts land; without it
# the card ships in the fallback face.
printf 'og: rendering with %s\n' "$chrome"

# $1 source page, $2 output, $3 width, $4 height
render() {
    "$chrome" --headless --disable-gpu --no-sandbox --hide-scrollbars \
        --virtual-time-budget=20000 --window-size="$3,$4" \
        --screenshot="$2" "file://$root/$1" >/dev/null 2>&1

    [ -f "$2" ] || die "no image was produced for $1"

    # `identify -format` prints no trailing newline, which makes `read` return
    # non-zero at EOF and, under `set -e`, kill the script after a good render.
    if command -v magick >/dev/null 2>&1; then
        dims=$(magick identify -format '%w %h' "$2")
        [ "$dims" = "$3 $4" ] || die "expected ${3}x${4} for $2, got ${dims/ /x}"
    fi

    printf 'og: %s is %s\n' "$2" "$(du -h "$2" | cut -f1)"
}

render tools/og.html docs/og.png 1200 630
render tools/thumb.html docs/thumb.png 480 480

printf 'og: check the fonts rendered as IBM Plex before committing\n'
