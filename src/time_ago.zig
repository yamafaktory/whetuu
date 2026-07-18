//! Human "time ago" formatting in atuin's compact style: only the most
//! significant unit, no suffix — "8m", "5d", "3mo". Relative durations are
//! pure elapsed-seconds arithmetic — no calendar or timezone — so this needs
//! no datetime library. Months and years use fixed 30- and 365-day
//! approximations, which is plenty for a history label.

const std = @import("std");

/// One time unit and how many seconds it spans.
const Unit = struct {
    /// Compact label ("m"); "mo" is the only two-letter unit, so "m"
    /// unambiguously means minutes.
    name: []const u8,
    seconds: u64,
};

/// Units from largest to smallest; the first that fits wins.
const units = [_]Unit{
    .{ .name = "y", .seconds = 365 * 24 * 60 * 60 },
    .{ .name = "mo", .seconds = 30 * 24 * 60 * 60 },
    .{ .name = "w", .seconds = 7 * 24 * 60 * 60 },
    .{ .name = "d", .seconds = 24 * 60 * 60 },
    .{ .name = "h", .seconds = 60 * 60 },
    .{ .name = "m", .seconds = 60 },
    .{ .name = "s", .seconds = 1 },
};

/// Formats how long ago `then` was relative to `now` (both unix seconds) into
/// `buf`, e.g. "0s", "8m", "3h", "5d". Returns an empty string when the
/// timestamp is unknown (0) or lies in the future, so callers can simply
/// render nothing.
pub fn relative(buf: []u8, now: i64, then: i64) []const u8 {
    if (then <= 0 or now < then) return "";

    const elapsed: u64 = @intCast(now - then);
    for (units) |unit| {
        if (elapsed < unit.seconds) continue;

        return std.fmt.bufPrint(buf, "{d}{s}", .{ elapsed / unit.seconds, unit.name }) catch "";
    }

    return "0s";
}

test "relative renders the most significant unit compactly" {
    var buf: [24]u8 = undefined;
    const now: i64 = 1_000_000_000;

    try std.testing.expectEqualStrings("0s", relative(&buf, now, now));
    try std.testing.expectEqualStrings("30s", relative(&buf, now, now - 30));
    try std.testing.expectEqualStrings("1m", relative(&buf, now, now - 60));
    try std.testing.expectEqualStrings("5m", relative(&buf, now, now - 5 * 60));
    try std.testing.expectEqualStrings("1h", relative(&buf, now, now - 60 * 60));
    try std.testing.expectEqualStrings("2d", relative(&buf, now, now - 2 * 24 * 60 * 60));
    try std.testing.expectEqualStrings("1w", relative(&buf, now, now - 7 * 24 * 60 * 60));
    try std.testing.expectEqualStrings("3mo", relative(&buf, now, now - 3 * 30 * 24 * 60 * 60));
    try std.testing.expectEqualStrings("2y", relative(&buf, now, now - 2 * 365 * 24 * 60 * 60));
}

test "relative returns empty for unknown or future timestamps" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("", relative(&buf, 1_000, 0));
    try std.testing.expectEqualStrings("", relative(&buf, 1_000, 2_000));
}
