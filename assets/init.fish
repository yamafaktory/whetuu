# whetuu — fish integration. Add to config.fish:  whetuu init fish | source
function fish_prompt
    # $status reflects the last command and must be captured before anything
    # else runs. fish provides $CMD_DURATION (ms) and $COLUMNS for free.
    set -l last_status $status
    whetuu prompt --shell fish --status $last_status --duration-ms $CMD_DURATION --width $COLUMNS
end

# Record each command line into whetuu's cross-shell history store. fish passes
# the command line to the fish_preexec handler as $argv.
function __whetuu_preexec --on-event fish_preexec
    command whetuu history add -- $argv
end

# Up-arrow opens the whetuu history picker and runs the chosen command right
# away. The picker draws on /dev/tty, so its stdout is only the choice.
function __whetuu_history
    set -l picked (command whetuu history | string collect)
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
