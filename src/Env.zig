//! Immutable snapshot of shell state for a single prompt render. Built once in
//! `main` from CLI flags plus the environment, then shared (read-only) with
//! every module running concurrently. Modules must not mutate it: it is shared
//! across threads.

const Env = @This();

/// Target shell.
shell: Shell,
/// Absolute current working directory.
cwd: []const u8,
/// Value of `$HOME`, used to collapse the directory to `~`.
home: []const u8,
/// Terminal width in columns; 0 when unknown.
width: u16,
/// Milliseconds the previous command ran, as reported by the shell.
duration_ms: u64,
/// Exit status of the previous command (0 = success).
exit_status: u8,

/// Which shell requested the prompt. Selects how non-printing escape sequences
/// are wrapped so the line editor counts prompt width correctly (see `style`).
pub const Shell = enum {
    bash,
    fish,
    zsh,
};
