# whetuu — zsh integration. Add to .zshrc:  eval "$(whetuu init zsh)"
zmodload zsh/datetime
autoload -Uz add-zsh-hook

__whetuu_start=""

__whetuu_preexec() {
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
    PROMPT="$(whetuu prompt --shell zsh --status $exit --duration-ms $dur_ms --width $COLUMNS)"
}

add-zsh-hook preexec __whetuu_preexec
add-zsh-hook precmd __whetuu_precmd
