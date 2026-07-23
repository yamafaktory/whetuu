#!/usr/bin/env bash
#
# Renders tools/og.html to docs/og.png, the 1200x630 image link previews show.
# Invoked by `zig build og`.
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
"$chrome" --headless --disable-gpu --no-sandbox --hide-scrollbars \
    --virtual-time-budget=20000 --window-size=1200,630 \
    --screenshot=docs/og.png "file://$root/tools/og.html" >/dev/null 2>&1

[ -f docs/og.png ] || die "no image was produced"

# `identify -format` prints no trailing newline, which makes `read` return
# non-zero at EOF and, under `set -e`, kill the script after a good render.
if command -v magick >/dev/null 2>&1; then
    dims=$(magick identify -format '%w %h' docs/og.png)
    [ "$dims" = "1200 630" ] || die "expected 1200x630, got ${dims/ /x}"
fi

printf 'og: docs/og.png is %s\n' "$(du -h docs/og.png | cut -f1)"
printf 'og: check the fonts rendered as IBM Plex before committing\n'
