# whetuu — fish integration. Add to config.fish:  whetuu init fish | source
function fish_prompt
    # $status reflects the last command and must be captured before anything
    # else runs. fish provides $CMD_DURATION (ms) and $COLUMNS for free.
    set -l last_status $status
    whetuu prompt --shell fish --status $last_status --duration-ms $CMD_DURATION --width $COLUMNS
end
