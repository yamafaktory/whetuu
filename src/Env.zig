//! Immutable snapshot of shell state for a single render. Built once in
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
/// Value of `$USER`; empty when unset.
user: []const u8 = "",
/// Value of `$PATH`, used to resolve a toolchain binary before probing it.
/// Empty disables the version cache, so every probe runs.
path: []const u8 = "",
/// Value of `$XDG_CACHE_HOME`; empty falls back to `$HOME/.cache`.
cache_home: []const u8 = "",
/// True when the shell runs over SSH (`$SSH_CONNECTION` or `$SSH_TTY` set).
ssh: bool = false,
/// Terminal width in columns; 0 when unknown.
width: u16,
/// Milliseconds the previous command ran, as reported by the shell.
duration_ms: u64,
/// Exit status of the previous command (0 = success).
exit_status: u8,

/// Which shell requested the render. Selects how non-printing escape sequences
/// are wrapped so the line editor counts the width correctly (see `style`).
pub const Shell = enum {
    bash,
    fish,
    zsh,
};
