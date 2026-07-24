# whetuu — zsh integration. Add to .zshrc:  eval "$(whetuu init zsh)"
zmodload zsh/datetime
autoload -Uz add-zsh-hook

__whetuu_cmd=""
__whetuu_start=""
__whetuu_failed=""
__whetuu_failed_at=""

# zsh hands preexec the full command line, so it is stashed here and recorded
# in precmd once the exit status is known.
__whetuu_preexec() {
    __whetuu_cmd=$1
    __whetuu_start=$EPOCHREALTIME
}

__whetuu_precmd() {
    local exit=$?
    local dur_ms=0
    if [[ -n "$__whetuu_start" ]]; then
        dur_ms=$(( (EPOCHREALTIME - __whetuu_start) * 1000 ))
        dur_ms=${dur_ms%.*}
        __whetuu_start=""
    fi
    if [[ -n "$__whetuu_cmd" ]]; then
        command whetuu history add --status $exit -- "$__whetuu_cmd"
        # Keep a command that did not exit 0 so the picker can show it at the
        # top without storing it, until the next command finishes. A clean run,
        # or a command opted out of history with a leading space, clears it.
        if [[ $exit -ne 0 && "$__whetuu_cmd" != [[:space:]]* ]]; then
            __whetuu_failed=$__whetuu_cmd
            __whetuu_failed_at=$EPOCHSECONDS
        else
            __whetuu_failed=""
            __whetuu_failed_at=""
        fi
        __whetuu_cmd=""
    fi
    PROMPT="$(whetuu render --shell zsh --status $exit --duration-ms $dur_ms --width $COLUMNS)"
}

add-zsh-hook preexec __whetuu_preexec
add-zsh-hook precmd __whetuu_precmd

# Up arrow opens the whetuu history picker and runs the chosen command right
# away, the same as the fish integration. Anything already typed seeds the
# picker's search field, and the last failed command is passed with --last so it
# appears marked at the top. Cancelling leaves the slot alone, so the failed
# command is still offered next time. The picker draws on /dev/tty, so its stdout
# is only the choice.
__whetuu_history() {
    local picked
    picked=$(command whetuu history --query "$BUFFER" --last "$__whetuu_failed" --last-at "$__whetuu_failed_at" </dev/tty)
    if [[ -n "$picked" ]]; then
        BUFFER=$picked
        CURSOR=${#BUFFER}
        zle accept-line
    else
        zle redisplay
    fi
}

if [[ -o interactive ]]; then
    zle -N __whetuu_history
    # Both the normal and the application cursor sequence, since which one the
    # terminal sends depends on keypad mode.
    bindkey '^[[A' __whetuu_history
    bindkey '^[OA' __whetuu_history
fi
