//! Command-duration module. Shows how long the previous command ran, but only
//! once it crosses a threshold worth noticing.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const Span = @import("style.zig").Span;
const style = @import("style.zig");

/// Minimum runtime before the segment appears. Below this the timing is noise.
const min_ms = 2_000;

/// Renders the duration segment, or null when the last command was fast or
/// allocation fails.
pub fn run(io: std.Io, arena: Allocator, ctx: *const Context) ?[]const Span {
    _ = io;
    if (ctx.duration_ms < min_ms) return null;

    const human = humanize(arena, ctx.duration_ms) catch return null;
    const text = std.fmt.allocPrint(arena, "⏱ {s}", .{human}) catch return null;
    return style.single(arena, .{ .color = .yellow }, text) catch null;
}

/// Formats milliseconds into a compact human string. Pure except for `arena`,
/// so it is unit-tested directly. Under a minute it shows one decimal of
/// seconds; larger durations drop to whole units.
fn humanize(arena: Allocator, ms: u64) Allocator.Error![]const u8 {
    const total_s = ms / 1000;
    if (total_s < 60) {
        const tenths = (ms % 1000) / 100;
        return std.fmt.allocPrint(arena, "{d}.{d}s", .{ total_s, tenths });
    }

    const s = total_s % 60;
    const total_m = total_s / 60;
    if (total_m < 60) {
        return std.fmt.allocPrint(arena, "{d}m{d}s", .{ total_m, s });
    }

    const m = total_m % 60;
    const h = total_m / 60;
    return std.fmt.allocPrint(arena, "{d}h{d}m{d}s", .{ h, m, s });
}

/// Runs `humanize` against a throwaway arena.
fn expectHuman(expected: []const u8, ms: u64) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const got = try humanize(arena.allocator(), ms);
    try std.testing.expectEqualStrings(expected, got);
}

test "seconds with one decimal" {
    try expectHuman("2.0s", 2_000);
    try expectHuman("2.5s", 2_500);
    try expectHuman("59.9s", 59_900);
}

test "minutes and seconds" {
    try expectHuman("1m30s", 90_000);
}

test "hours, minutes, seconds" {
    try expectHuman("1h1m1s", 3_661_000);
}

test "below threshold renders nothing" {
    const ctx: Context = .{
        .cwd = "/",
        .duration_ms = 1_000,
        .exit_status = 0,
        .home = "/home/davy",
        .shell = .fish,
        .width = 80,
    };
    try std.testing.expect(run(undefined, std.testing.allocator, &ctx) == null);
}
