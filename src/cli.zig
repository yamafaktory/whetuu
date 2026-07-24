//! Minimal flag parsing for the `render` and `history add` subcommands. The
//! shell init scripts are the only callers, so the accepted flags are fixed
//! and few.

const std = @import("std");

const Shell = @import("Env.zig").Shell;

/// Values parsed from `whetuu history add`: the exit status the shell reported
/// for the command and the command words following `--`.
pub const HistoryAddArgs = struct {
    exit_status: u8 = 0,
    words: []const [:0]const u8 = &.{},
};

/// Values parsed from the picker form of `whetuu history`: the query seeded
/// from the shell's command line, the command that just failed (shown unstored
/// at the top of the list), and the unix time it failed at so its age counts up
/// from when it ran rather than from when the picker opened.
pub const HistoryPickArgs = struct {
    query: []const u8 = "",
    last: []const u8 = "",
    last_at: i64 = 0,
};

/// Values parsed from `whetuu render` flags. Fields default to a usable status
/// line even when a shell omits a flag.
pub const RenderArgs = struct {
    shell: Shell = .fish,
    width: u16 = 0,
    duration_ms: u64 = 0,
    exit_status: u8 = 0,
};

/// Error set for flag parsing; the message detail is reported by the caller.
pub const ParseError = error{
    MissingValue,
    UnknownFlag,
    UnknownShell,
    InvalidNumber,
};

/// Parses `[--status N] [--] <word>...` for `history add`. The words after the
/// optional `--` are the recorded command; `--status` carries the exit status
/// of that command so the caller can drop failures. The first token that is
/// neither recognized flag nor `--` starts the command words, keeping the
/// pre-flag `history add <command>` form working.
pub fn parseHistoryAdd(args: []const [:0]const u8) ParseError!HistoryAddArgs {
    var result: HistoryAddArgs = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--")) {
            result.words = args[i + 1 ..];
            return result;
        }

        if (!std.mem.eql(u8, arg, "--status")) {
            result.words = args[i..];
            return result;
        }

        if (i + 1 >= args.len) return error.MissingValue;

        i += 1;
        result.exit_status = parseClamped(u8, args[i]) catch return error.InvalidNumber;
    }

    return result;
}

/// Parses `[--query <text>] [--last <command>] [--last-at <unix>]` for the
/// history picker, in any order. Every flag takes a value, so a trailing flag
/// without one is an error; an unrecognized flag is rejected so a typo in an
/// init script surfaces rather than being silently opened as an empty picker.
pub fn parseHistoryPick(args: []const [:0]const u8) ParseError!HistoryPickArgs {
    var result: HistoryPickArgs = .{};

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const flag = args[i];
        if (i + 1 >= args.len) return error.MissingValue;

        i += 1;
        const value = args[i];

        if (std.mem.eql(u8, flag, "--query")) {
            result.query = value;
        } else if (std.mem.eql(u8, flag, "--last")) {
            result.last = value;
        } else if (std.mem.eql(u8, flag, "--last-at")) {
            // Lenient: an unset shell variable arrives empty, and a bad clock is
            // not worth failing the whole picker over — either just means "now".
            result.last_at = std.fmt.parseInt(i64, value, 10) catch 0;
        } else {
            return error.UnknownFlag;
        }
    }

    return result;
}

/// Parses `--shell`, `--status`, `--duration-ms`, and `--width` from `args`
/// (which must exclude argv[0] and the subcommand). Unknown numeric values that
/// overflow are clamped rather than rejected, since a shell can legitimately
/// report a huge duration.
pub fn parseRender(args: []const [:0]const u8) ParseError!RenderArgs {
    var result: RenderArgs = .{};

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
/// is unset (e.g. bash's first status line has no recorded duration).
fn parseClamped(comptime T: type, text: []const u8) error{Invalid}!T {
    if (text.len == 0) return 0;
    return std.fmt.parseInt(T, text, 10) catch |err| switch (err) {
        error.Overflow => std.math.maxInt(T),
        error.InvalidCharacter => error.Invalid,
    };
}

test "parses all flags" {
    const args = [_][:0]const u8{ "--shell", "zsh", "--status", "1", "--duration-ms", "1500", "--width", "120" };
    const got = try parseRender(&args);
    try std.testing.expectEqual(Shell.zsh, got.shell);
    try std.testing.expectEqual(@as(u8, 1), got.exit_status);
    try std.testing.expectEqual(@as(u64, 1500), got.duration_ms);
    try std.testing.expectEqual(@as(u16, 120), got.width);
}

test "empty numeric value is zero" {
    const args = [_][:0]const u8{ "--duration-ms", "" };
    const got = try parseRender(&args);
    try std.testing.expectEqual(@as(u64, 0), got.duration_ms);
}

test "overflow saturates to max" {
    const args = [_][:0]const u8{ "--status", "99999" };
    const got = try parseRender(&args);
    try std.testing.expectEqual(@as(u8, 255), got.exit_status);
}

test "unknown shell is rejected" {
    const args = [_][:0]const u8{ "--shell", "tcsh" };
    try std.testing.expectError(error.UnknownShell, parseRender(&args));
}

test "history add parses status then command words after --" {
    const args = [_][:0]const u8{ "--status", "1", "--", "git", "push" };
    const got = try parseHistoryAdd(&args);
    try std.testing.expectEqual(@as(u8, 1), got.exit_status);
    try std.testing.expectEqual(@as(usize, 2), got.words.len);
    try std.testing.expectEqualStrings("git", got.words[0]);
    try std.testing.expectEqualStrings("push", got.words[1]);
}

test "history add defaults to success and -- is optional" {
    const args = [_][:0]const u8{"ls"};
    const got = try parseHistoryAdd(&args);
    try std.testing.expectEqual(@as(u8, 0), got.exit_status);
    try std.testing.expectEqual(@as(usize, 1), got.words.len);
    try std.testing.expectEqualStrings("ls", got.words[0]);
}

test "history add rejects a missing status value" {
    const args = [_][:0]const u8{"--status"};
    try std.testing.expectError(error.MissingValue, parseHistoryAdd(&args));
}

test "history pick reads query, last, and last-at in any order" {
    const args = [_][:0]const u8{ "--last", "gti status", "--query", "gt", "--last-at", "1700000000" };
    const got = try parseHistoryPick(&args);
    try std.testing.expectEqualStrings("gt", got.query);
    try std.testing.expectEqualStrings("gti status", got.last);
    try std.testing.expectEqual(@as(i64, 1_700_000_000), got.last_at);
}

test "history pick defaults to empty, and a blank last-at is zero" {
    const got = try parseHistoryPick(&.{});
    try std.testing.expectEqualStrings("", got.query);
    try std.testing.expectEqualStrings("", got.last);
    try std.testing.expectEqual(@as(i64, 0), got.last_at);

    const blank = [_][:0]const u8{ "--last-at", "" };
    try std.testing.expectEqual(@as(i64, 0), (try parseHistoryPick(&blank)).last_at);
}

test "history pick rejects a flag without a value" {
    const args = [_][:0]const u8{"--last"};
    try std.testing.expectError(error.MissingValue, parseHistoryPick(&args));
}

test "history pick rejects an unknown flag" {
    const args = [_][:0]const u8{ "--nope", "x" };
    try std.testing.expectError(error.UnknownFlag, parseHistoryPick(&args));
}
