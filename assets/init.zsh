# whetuu — zsh integration. Add to .zshrc:  eval "$(whetuu init zsh)"
zmodload zsh/datetime
autoload -Uz add-zsh-hook

__whetuu_cmd=""
__whetuu_start=""

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
        __whetuu_cmd=""
    fi
    PROMPT="$(whetuu prompt --shell zsh --status $exit --duration-ms $dur_ms --width $COLUMNS)"
}

add-zsh-hook preexec __whetuu_preexec
add-zsh-hook precmd __whetuu_precmd
