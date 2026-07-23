# whetuu — fish integration. Add to config.fish:  whetuu init fish | source
function fish_prompt
    # $status reflects the last command and must be captured before anything
    # else runs. fish provides $CMD_DURATION (ms) and $COLUMNS for free.
    set -l last_status $status
    whetuu prompt --shell fish --status $last_status --duration-ms $CMD_DURATION --width $COLUMNS
end

# Record each command line into whetuu's cross-shell history store once it has
# finished. fish passes the command line as $argv and $status still holds the
# command's exit status; whetuu drops anything that did not exit 0.
#
# A command that did not exit 0 is also kept in $__whetuu_failed, so the picker
# can show it at the top without ever storing it. The slot lives until the next
# command finishes. A clean exit, or a command opted out of history with a
# leading space, clears it instead.
function __whetuu_postexec --on-event fish_postexec
    set -l last_status $status
    command whetuu history add --status $last_status -- $argv
    if test $last_status -ne 0; and not string match -qr '^\s' -- "$argv"
        set -g __whetuu_failed $argv
        set -g __whetuu_failed_at (date +%s)
    else
        set -e __whetuu_failed
        set -e __whetuu_failed_at
    end
end

# Up-arrow opens the whetuu history picker and runs the chosen command right
# away. Anything already typed on the command line seeds the picker's search
# field, and the last failed command is passed with --last so it appears marked
# at the top. Cancelling the picker leaves the slot alone, so the failed command
# is still offered next time. The picker draws on /dev/tty, so its stdout is only
# the choice.
function __whetuu_history
    set -l initial (commandline)
    set -l picked (command whetuu history --query "$initial" --last "$__whetuu_failed" --last-at "$__whetuu_failed_at" | string collect)
    if test -n "$picked"
        commandline --replace -- $picked
        commandline -f execute
    else
        commandline -f repaint
    end
end

if status is-interactive
    bind up __whetuu_history
end
