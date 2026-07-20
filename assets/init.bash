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

# A leading space means "do not record this", but bash's `history` output cannot
# preserve it — the command is read back with its indentation already gone. So
# the opt-out is delegated to bash itself: with `ignorespace` such a command
# never enters bash's history, so it never reaches the recorder below either.
# Any existing HISTCONTROL setting is kept.
case ":$HISTCONTROL:" in
    *:ignorespace:* | *:ignoreboth:*) ;;
    *) HISTCONTROL="${HISTCONTROL:+$HISTCONTROL:}ignorespace" ;;
esac

# Seed with the newest entry of the loaded history file so it is not recorded
# as if it had just run when the first prompt draws.
__whetuu_last_hist=""
read -r __whetuu_last_hist _ <<<"$(HISTTIMEFORMAT= history 1)"

# Record the command that just finished, forwarding its exit status so whetuu
# drops anything that did not exit 0. The history number guards against
# re-recording when the prompt redraws without a new command (plain Enter).
__whetuu_record() {
    local num cmd
    read -r num cmd <<<"$(HISTTIMEFORMAT= history 1)"
    [[ -z "$num" || "$num" == "$__whetuu_last_hist" ]] && return
    __whetuu_last_hist="$num"
    command whetuu history add --status "$1" -- "$cmd"
}

__whetuu_precmd() {
    local exit=$?
    __whetuu_record "$exit"
    local dur_ms=0
    if [[ -n "$__whetuu_start" ]]; then
        local now="${EPOCHREALTIME/./}"
        dur_ms=$(( (now - __whetuu_start) / 1000 ))
        __whetuu_start=""
    fi
    PS1="$(whetuu prompt --shell bash --status "$exit" --duration-ms "$dur_ms" --width "$COLUMNS")"
}
PROMPT_COMMAND=__whetuu_precmd
