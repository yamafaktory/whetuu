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

# A stand in for whetuu that logs every recorded command, so the fish and zsh
# checks below can see what reached the store without a real one.
fake=$(mktemp -d)
trap 'rm -rf "$fake"' EXIT
cat >"$fake/whetuu" <<'SH'
#!/bin/sh
[ "$1" = history ] && [ "$2" = add ] && shift 5 && printf '%s\n' "$*" >>"$WHETUU_TEST_LOG"
exit 0
SH
chmod +x "$fake/whetuu"

# Runs one command through the fish integration's postexec hook and prints
# what was recorded, then the failed slot.
fish_records() {
    local log="$fake/fish.log"
    : >"$log"
    PATH="$fake:$PATH" WHETUU_TEST_LOG="$log" fish --no-config -c "
        source $root/assets/init.fish
        $1
        $2; __whetuu_postexec '$3'
        printf 'failed=%s' \"\$__whetuu_failed\"
    " >"$fake/fish.out" 2>&1
    printf '%s|%s' "$(cat "$log")" "$(cat "$fake/fish.out")"
}

# The same through the zsh integration's preexec and precmd hooks.
zsh_records() {
    local log="$fake/zsh.log"
    : >"$log"
    PATH="$fake:$PATH" WHETUU_TEST_LOG="$log" zsh -f -c "
        source $root/assets/init.zsh
        $1
        __whetuu_preexec '$3'; $2; __whetuu_precmd
        printf 'failed=%s' \"\$__whetuu_failed\"
    " >"$fake/zsh.out" 2>&1
    printf '%s|%s' "$(cat "$log")" "$(cat "$fake/zsh.out")"
}

if command -v fish >/dev/null; then
    check "fish records a command" \
        "ls|failed=" \
        "$(fish_records '' true 'ls')"

    check "fish keeps out what fish_should_add_to_history refuses" \
        "|failed=" \
        "$(fish_records 'function fish_should_add_to_history; not string match -q "vault*" -- $argv; end' true 'vault read x')"

    check "fish clears the failed slot for a refused command" \
        "|failed=" \
        "$(fish_records 'function fish_should_add_to_history; not string match -q "vault*" -- $argv; end; set -g __whetuu_failed old' false 'vault read x')"

    check "fish still records what fish_should_add_to_history accepts" \
        "ls|failed=" \
        "$(fish_records 'function fish_should_add_to_history; not string match -q "vault*" -- $argv; end' true 'ls')"
else
    printf 'skip fish is not installed\n'
fi

if command -v zsh >/dev/null; then
    check "zsh records a command" \
        "ls|failed=" \
        "$(zsh_records '' true 'ls')"

    check "zsh keeps out what HISTORY_IGNORE matches" \
        "|failed=" \
        "$(zsh_records 'HISTORY_IGNORE="(vault *|pass *)"' true 'vault read x')"

    check "zsh clears the failed slot for an ignored command" \
        "|failed=" \
        "$(zsh_records 'HISTORY_IGNORE="(vault *)"; __whetuu_failed=old' false 'vault read x')"

    check "zsh still records what HISTORY_IGNORE does not match" \
        "ls|failed=" \
        "$(zsh_records 'HISTORY_IGNORE="(vault *)"' true 'ls')"
else
    printf 'skip zsh is not installed\n'
fi

if [ "$failures" -ne 0 ]; then
    printf '\n%s check(s) failed\n' "$failures" >&2
    exit 1
fi
printf '\nall init checks passed\n'
