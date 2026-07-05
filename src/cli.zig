//! Minimal flag parsing for the `prompt` subcommand. The shell init scripts are
//! the only callers, so the accepted flags are fixed and few.

const std = @import("std");

const Shell = @import("context.zig").Shell;

/// Values parsed from `whetuu prompt` flags. Fields default to a usable prompt
/// even when a shell omits a flag.
pub const PromptArgs = struct {
    duration_ms: u64 = 0,
    exit_status: u8 = 0,
    shell: Shell = .fish,
    width: u16 = 0,
};

/// Error set for flag parsing; the message detail is reported by the caller.
pub const ParseError = error{
    MissingValue,
    UnknownFlag,
    UnknownShell,
    InvalidNumber,
};

/// Parses `--shell`, `--status`, `--duration-ms`, and `--width` from `args`
/// (which must exclude argv[0] and the subcommand). Unknown numeric values that
/// overflow are clamped rather than rejected, since a shell can legitimately
/// report a huge duration.
pub fn parsePrompt(args: []const [:0]const u8) ParseError!PromptArgs {
    var result: PromptArgs = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (i + 1 >= args.len) return error.MissingValue;

        i += 1;
        const value = args[i];

        if (std.mem.eql(u8, flag, "--shell")) {
            result.shell = std.meta.stringToEnum(Shell, value) orelse return error.UnknownShell;
        } else if (std.mem.eql(u8, flag, "--status")) {
            result.exit_status = parseClamped(u8, value) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, flag, "--duration-ms")) {
            result.duration_ms = parseClamped(u64, value) catch return error.InvalidNumber;
        } else if (std.mem.eql(u8, flag, "--width")) {
            result.width = parseClamped(u16, value) catch return error.InvalidNumber;
        } else {
            return error.UnknownFlag;
        }
    }

    return result;
}

/// Parses an unsigned integer, saturating to the type maximum on overflow.
/// Empty strings parse as 0 because shells pass an empty value when a variable
/// is unset (e.g. bash's first prompt has no recorded duration).
fn parseClamped(comptime T: type, text: []const u8) error{Invalid}!T {
    if (text.len == 0) return 0;

    return std.fmt.parseInt(T, text, 10) catch |err| switch (err) {
        error.Overflow => std.math.maxInt(T),
        error.InvalidCharacter => error.Invalid,
    };
}

test "parses all flags" {
    const args = [_][:0]const u8{ "--shell", "zsh", "--status", "1", "--duration-ms", "1500", "--width", "120" };
    const got = try parsePrompt(&args);
    try std.testing.expectEqual(Shell.zsh, got.shell);
    try std.testing.expectEqual(@as(u8, 1), got.exit_status);
    try std.testing.expectEqual(@as(u64, 1500), got.duration_ms);
    try std.testing.expectEqual(@as(u16, 120), got.width);
}

test "empty numeric value is zero" {
    const args = [_][:0]const u8{ "--duration-ms", "" };
    const got = try parsePrompt(&args);
    try std.testing.expectEqual(@as(u64, 0), got.duration_ms);
}

test "overflow saturates to max" {
    const args = [_][:0]const u8{ "--status", "99999" };
    const got = try parsePrompt(&args);
    try std.testing.expectEqual(@as(u8, 255), got.exit_status);
}

test "unknown shell is rejected" {
    const args = [_][:0]const u8{ "--shell", "tcsh" };
    try std.testing.expectError(error.UnknownShell, parsePrompt(&args));
}
