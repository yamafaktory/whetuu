# whetuu — bash integration. Add to .bashrc:  eval "$(whetuu init bash)"
# Requires bash 5+ for EPOCHREALTIME (microsecond wall clock).

__whetuu_start=""
__whetuu_failed=""
__whetuu_failed_at=""

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
# as if it had just run when the first status line draws.
__whetuu_last_hist=""
read -r __whetuu_last_hist _ <<<"$(HISTTIMEFORMAT= history 1)"

# Record the command that just finished, forwarding its exit status so whetuu
# drops anything that did not exit 0. The history number guards against
# re-recording when the status line redraws without a new command (plain Enter).
__whetuu_record() {
    local num cmd
    read -r num cmd <<<"$(HISTTIMEFORMAT= history 1)"
    [[ -z "$num" || "$num" == "$__whetuu_last_hist" ]] && return
    __whetuu_last_hist="$num"
    command whetuu history add --status "$1" -- "$cmd"
    # Keep a command that did not exit 0 so the picker can show it at the top
    # without storing it, until the next command finishes. A clean run clears the
    # slot. A leading space is already dropped by ignorespace, so such a command
    # never reaches here to be kept.
    if [[ "$1" -eq 0 ]]; then
        __whetuu_failed=""
        __whetuu_failed_at=""
    else
        __whetuu_failed="$cmd"
        __whetuu_failed_at="$EPOCHSECONDS"
    fi
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
    PS1="$(whetuu render --shell bash --status "$exit" --duration-ms "$dur_ms" --width "$COLUMNS")"
}
PROMPT_COMMAND=__whetuu_precmd

# Up arrow opens the whetuu history picker and runs the chosen command right
# away, the same as the fish and zsh integrations. Anything already typed seeds
# the picker's search field, and the last failed command is passed with --last
# so it appears marked at the top. Cancelling leaves the slot alone, so the
# failed command is still offered next time. The picker draws on /dev/tty, so its
# stdout is only the choice.
#
# A `bind -x` function cannot run a command itself, so the key expands to a
# two-step macro: the function first, then a follow-up key. The function decides
# what that follow-up key does before readline gets to it, which is how the
# choice is run but a cancel is not. readline resolves each key of a macro as it
# reads it, so rebinding from inside the function takes effect in time.
__whetuu_history() {
    local picked
    picked=$(command whetuu history --query "$READLINE_LINE" --last "$__whetuu_failed" --last-at "$__whetuu_failed_at" </dev/tty)
    if [[ -n "$picked" ]]; then
        READLINE_LINE="$picked"
        READLINE_POINT=${#READLINE_LINE}
        bind '"\C-x\C-z": accept-line'
    else
        # Cancelled. Leave the line alone and make the follow-up key harmless.
        bind '"\C-x\C-z": redraw-current-line'
    fi
}

if [[ $- == *i* ]]; then
    bind -x '"\C-x\C-w": __whetuu_history'
    bind '"\C-x\C-z": redraw-current-line'
    # Both the normal and the application cursor sequence, since which one the
    # terminal sends depends on keypad mode.
    bind '"\e[A": "\C-x\C-w\C-x\C-z"'
    bind '"\eOA": "\C-x\C-w\C-x\C-z"'
fi
