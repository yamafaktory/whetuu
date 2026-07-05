# whetuu — bash integration. Add to .bashrc:  eval "$(whetuu init bash)"
# Requires bash 5+ for EPOCHREALTIME (microsecond wall clock).

__whetuu_start=""

# Record a start time before each interactive command. Skip completion and the
# precmd hook itself so they are not measured.
__whetuu_preexec() {
    [[ -n "$COMP_LINE" ]] && return
    [[ "$BASH_COMMAND" == "__whetuu_precmd" ]] && return
    __whetuu_start="${EPOCHREALTIME/./}"
}
trap '__whetuu_preexec' DEBUG

__whetuu_precmd() {
    local exit=$?
    local dur_ms=0
    if [[ -n "$__whetuu_start" ]]; then
        local now="${EPOCHREALTIME/./}"
        dur_ms=$(( (now - __whetuu_start) / 1000 ))
        __whetuu_start=""
    fi
    PS1="$(whetuu prompt --shell bash --status "$exit" --duration-ms "$dur_ms" --width "$COLUMNS")"
}
PROMPT_COMMAND=__whetuu_precmd
