#!/usr/bin/env bash
#
# Behaviour checks for the bash integration, which `zig build test` cannot
# reach. Run by CI next to shellcheck.
#
# PROMPT_COMMAND is a list the shell shares with everything else that wants a
# hook each prompt. Assigning to it rather than joining it silently dropped
# whatever was already registered, so these checks pin the joining down.

# The snippets below are single quoted on purpose: their $1 is the init script
# path, expanded by the inner bash rather than by this one. That is every
# SC2016 in this file.
# shellcheck disable=SC2016

set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
readonly init="$root/assets/init.bash"
failures=0

# Each case runs in its own non-interactive bash so none can leak into the next.
# The interactive-only key bindings are skipped there, which is fine: every
# assertion here is about PROMPT_COMMAND.
hooks() {
    bash --norc -c "$1"' >/dev/null 2>&1; printf "%s" "${PROMPT_COMMAND[*]}"' bash "$init"
}

check() {
    local name=$1 expected=$2 actual=$3
    if [ "$expected" = "$actual" ]; then
        printf 'ok   %s\n' "$name"
        return
    fi
    printf 'FAIL %s\n       expected: %s\n       actual:   %s\n' "$name" "$expected" "$actual"
    failures=$((failures + 1))
}

check "an existing hook survives" \
    "__whetuu_precmd other_hook" \
    "$(hooks 'PROMPT_COMMAND=other_hook; source "$1"')"

check "whetuu goes first, so it reads the command's own exit status" \
    "__whetuu_precmd a b" \
    "$(hooks 'PROMPT_COMMAND=(a b); source "$1"')"

check "sourcing twice registers one hook" \
    "__whetuu_precmd other_hook" \
    "$(hooks 'PROMPT_COMMAND=other_hook; source "$1"; source "$1"')"

check "an unset PROMPT_COMMAND just gets whetuu" \
    "__whetuu_precmd" \
    "$(hooks 'unset PROMPT_COMMAND; source "$1"')"

if [ "$failures" -ne 0 ]; then
    printf '\n%s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall init checks passed\n'
