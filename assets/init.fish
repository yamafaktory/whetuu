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
function __whetuu_postexec --on-event fish_postexec
    set -l last_status $status
    command whetuu history add --status $last_status -- $argv
end

# Up-arrow opens the whetuu history picker and runs the chosen command right
# away. Anything already typed on the command line seeds the picker's search
# field. The picker draws on /dev/tty, so its stdout is only the choice.
function __whetuu_history
    set -l initial (commandline)
    set -l picked (command whetuu history --query "$initial" | string collect)
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
