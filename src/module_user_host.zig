//! user@host module. Shown only when it carries information: over SSH (so a
//! remote session is unmistakable) or when running as root (then in red, as a
//! warning). On a local, non-root shell it renders nothing — the zero-config
//! answer to "which box am I on?".

const std = @import("std");
const Allocator = std.mem.Allocator;
const posix = std.posix;

const Env = @import("Env.zig");
const Span = @import("style.zig").Span;
const style = @import("style.zig");

/// Renders `user@host`, or null on a local, non-root shell. Root turns the
/// whole segment red whether local or remote.
pub fn run(arena: Allocator, env: *const Env) ?[]const Span {
    const root = posix.system.getuid() == 0;
    if (!env.ssh and !root) return null;

    var buf: [posix.HOST_NAME_MAX]u8 = undefined;
    const user = if (env.user.len > 0) env.user else if (root) "root" else "?";
    const text = std.fmt.allocPrint(arena, "{s}@{s}", .{ user, hostname(&buf) }) catch return null;
    const color: style.Color = if (root) .red else .green;
    return style.single(arena, .{ .bold = true, .color = color }, text) catch null;
}

/// The machine's short host name: everything before the first `.` of the
/// kernel-reported name, "?" when even that is unavailable.
fn hostname(buf: *[posix.HOST_NAME_MAX]u8) []const u8 {
    const name = posix.gethostname(buf) catch return "?";
    const dot = std.mem.indexOfScalar(u8, name, '.') orelse return name;
    return name[0..dot];
}

test "hidden on a local, non-root shell" {
    const env: Env = .{
        .shell = .fish,
        .cwd = "/",
        .home = "/home/davy",
        .user = "davy",
        .width = 80,
        .duration_ms = 0,
        .exit_status = 0,
    };
    try std.testing.expect(run(std.testing.allocator, &env) == null or posix.system.getuid() == 0);
}

test "shown over ssh with user and host joined by @" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const env: Env = .{
        .shell = .fish,
        .cwd = "/",
        .home = "/home/davy",
        .user = "davy",
        .ssh = true,
        .width = 80,
        .duration_ms = 0,
        .exit_status = 0,
    };
    const spans = run(arena.allocator(), &env).?;
    try std.testing.expectEqual(@as(usize, 1), spans.len);
    try std.testing.expect(std.mem.startsWith(u8, spans[0].text, "davy@"));
    try std.testing.expect(spans[0].style.bold);
}
