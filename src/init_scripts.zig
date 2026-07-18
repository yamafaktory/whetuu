//! `whetuu init <shell>` — prints the shell integration script to stdout. The
//! scripts are embedded at compile time so the binary is self-contained.

const std = @import("std");

const Io = std.Io;
const Shell = @import("context.zig").Shell;

const bash_init = @embedFile("init.bash");
const fish_init = @embedFile("init.fish");
const zsh_init = @embedFile("init.zsh");

/// Returns the embedded integration script for `shell_name`, or
/// `error.UnknownShell` for an unrecognized shell. Pure, so the shell-name
/// dispatch is testable without touching stdout.
fn script(shell_name: []const u8) error{UnknownShell}![]const u8 {
    const shell = std.meta.stringToEnum(Shell, shell_name) orelse return error.UnknownShell;

    return switch (shell) {
        .bash => bash_init,
        .fish => fish_init,
        .zsh => zsh_init,
    };
}

/// Writes the integration script for `shell_name` to stdout. Returns
/// `error.UnknownShell` for an unrecognized shell.
pub fn write(io: Io, shell_name: []const u8) !void {
    const source = try script(shell_name);

    var buf: [256]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(source);
    try fw.interface.flush();
}

test "every supported shell resolves to its embedded script" {
    for ([_][]const u8{ "bash", "fish", "zsh" }) |name| {
        const source = try script(name);
        try std.testing.expect(std.mem.indexOf(u8, source, "whetuu") != null);
    }
}

test "unrecognized shell is rejected" {
    try std.testing.expectError(error.UnknownShell, script("powershell"));
    try std.testing.expectError(error.UnknownShell, script(""));
}
