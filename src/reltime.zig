//! Human "time ago" formatting. Relative durations are pure elapsed-seconds
//! arithmetic — no calendar or timezone — so this needs no datetime library.
//! Months and years use fixed 30- and 365-day approximations, which is plenty
//! for a history label like "3 months ago".

const std = @import("std");

/// One time unit and how many seconds it spans.
const Unit = struct {
    /// Singular noun ("min"); the plural just appends "s".
    name: []const u8,
    seconds: u64,
};

/// Units from largest to smallest; the first that fits wins.
const units = [_]Unit{
    .{ .name = "year", .seconds = 365 * 24 * 60 * 60 },
    .{ .name = "month", .seconds = 30 * 24 * 60 * 60 },
    .{ .name = "week", .seconds = 7 * 24 * 60 * 60 },
    .{ .name = "day", .seconds = 24 * 60 * 60 },
    .{ .name = "hour", .seconds = 60 * 60 },
    .{ .name = "min", .seconds = 60 },
};

/// Formats how long ago `then` was relative to `now` (both unix seconds) into
/// `buf`, e.g. "just now", "1 min ago", "3 hours ago". Returns an empty string
/// when the timestamp is unknown (0) or lies in the future, so callers can
/// simply render nothing.
pub fn relative(buf: []u8, now: i64, then: i64) []const u8 {
    if (then <= 0 or now < then) return "";

    const elapsed: u64 = @intCast(now - then);
    for (units) |unit| {
        if (elapsed < unit.seconds) continue;

        const n = elapsed / unit.seconds;
        const plural = if (n == 1) "" else "s";

        return std.fmt.bufPrint(buf, "{d} {s}{s} ago", .{ n, unit.name, plural }) catch "";
    }

    return "just now";
}

test "relative renders coarse buckets with pluralization" {
    var buf: [24]u8 = undefined;
    const now: i64 = 1_000_000_000;

    try std.testing.expectEqualStrings("just now", relative(&buf, now, now));
    try std.testing.expectEqualStrings("just now", relative(&buf, now, now - 30));
    try std.testing.expectEqualStrings("1 min ago", relative(&buf, now, now - 60));
    try std.testing.expectEqualStrings("5 mins ago", relative(&buf, now, now - 5 * 60));
    try std.testing.expectEqualStrings("1 hour ago", relative(&buf, now, now - 60 * 60));
    try std.testing.expectEqualStrings("2 days ago", relative(&buf, now, now - 2 * 24 * 60 * 60));
    try std.testing.expectEqualStrings("3 months ago", relative(&buf, now, now - 3 * 30 * 24 * 60 * 60));
}

test "relative returns empty for unknown or future timestamps" {
    var buf: [24]u8 = undefined;
    try std.testing.expectEqualStrings("", relative(&buf, 1_000, 0));
    try std.testing.expectEqualStrings("", relative(&buf, 1_000, 2_000));
}
