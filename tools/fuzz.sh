#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
crash="$root/.zig-cache/f/crash"

rm -f "$crash"
(cd "$root" && zig build test --fuzz="${1:-100K}")
if [ -f "$crash" ]; then
    echo "a fuzz target failed. Its input is in $crash" >&2
    exit 1
fi
