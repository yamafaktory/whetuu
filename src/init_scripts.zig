//! `whetuu init <shell>` — prints the shell integration script to stdout. The
//! scripts are embedded at compile time so the binary is self-contained.

const std = @import("std");

const Io = std.Io;
const Shell = @import("context.zig").Shell;

const bash_init = @embedFile("init.bash");
const fish_init = @embedFile("init.fish");
const zsh_init = @embedFile("init.zsh");

/// Writes the integration script for `shell_name` to stdout. Returns
/// `error.UnknownShell` for an unrecognized shell.
pub fn write(io: Io, shell_name: []const u8) !void {
    const shell = std.meta.stringToEnum(Shell, shell_name) orelse return error.UnknownShell;
    const script = switch (shell) {
        .bash => bash_init,
        .fish => fish_init,
        .zsh => zsh_init,
    };

    var buf: [256]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(script);
    try fw.interface.flush();
}
