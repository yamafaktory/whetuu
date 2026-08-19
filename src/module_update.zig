//! New-release module. Shows a cloud glyph and the newer version when one has
//! been published, and nothing at all the rest of the time.
//!
//! It reads the tag `whetuu upgrade --check` wrote and never the network: a render has
//! milliseconds, and a round trip to GitHub has none of them. When what it
//! reads is a day old the module starts that check as a detached child and
//! renders the answer it already had, so the new tag appears at a later prompt
//! rather than holding this one up.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const build_options = @import("build_options");

const Env = @import("Env.zig");
const Span = @import("style.zig").Span;
const release = @import("release.zig");
const style = @import("style.zig");

/// Segment glyph: nf-md-cloud_download.
const icon = "\u{f0162}";

/// Renders the segment, or null when there is nothing newer than this binary —
/// which is the usual answer, and also what a build from source always gets,
/// since `dev` compares with nothing.
pub fn run(io: Io, arena: Allocator, env: *const Env) ?[]const Span {
    // A build from source reports `dev`, which compares with nothing. There is
    // no notice it could ever show, so it asks GitHub nothing either.
    if (release.version(build_options.version) == null) return null;

    // Both buffers are the module's own, so the usual answer — nothing to say —
    // costs one open, one read, and not a single allocation.
    var path_buf: [release.path_buf_len]u8 = undefined;
    const path = release.cachePath(&path_buf, env.cache_home, env.home) orelse return null;
    var line_buf: [release.line_buf_len]u8 = undefined;
    const cached = release.readCache(io, path, &line_buf);

    if (release.isStale(cached, now(io))) startCheck(io, arena, path, cached);

    const tag = newer(build_options.version, cached) orelse return null;
    const text = std.fmt.allocPrint(arena, icon ++ " {s}", .{tag}) catch return null;
    return style.single(arena, .{ .rgb = style.purple }, text) catch null;
}

/// The remembered tag when it names a release newer than `current`, else null.
/// Pure, so the decision the segment turns on is testable on its own.
fn newer(current: []const u8, cached: ?release.Checked) ?[]const u8 {
    const running = release.version(current) orelse return null;
    const c = cached orelse return null;
    const latest = release.version(c.tag) orelse return null;
    return if (latest.order(running) == .gt) c.tag else null;
}

/// Starts `whetuu upgrade --check` and does not wait for it. Nothing here can be allowed
/// to touch the terminal or outlive its usefulness:
///
/// - the three streams go to `/dev/null`, so a message from the child can never
///   land in the middle of a status line
/// - it gets a process group of its own, so no shell reports it as a job
/// - nobody waits on it. This render exits within milliseconds, and the child
///   is reparented and reaped by init
///
/// The time is stamped here, before the child starts, so a check that never
/// finishes — or a cache directory that refuses the write — costs one attempt a
/// day rather than one per prompt. A failed stamp means the file cannot be
/// written at all, and then there is no point starting anything.
fn startCheck(io: Io, arena: Allocator, path: []const u8, cached: ?release.Checked) void {
    const kept = if (cached) |c| c.tag else "";
    if (!release.writeCache(io, path, kept, now(io))) return;

    const exe = std.process.executablePathAlloc(io, arena) catch return;
    _ = std.process.spawn(io, .{
        .argv = &.{ exe, "upgrade", "--check" },
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch return;
}

fn now(io: Io) i64 {
    return Io.Clock.now(.real, io).toSeconds();
}

test "the segment appears only for a release newer than this binary" {
    const day = release.ttl_seconds;

    // Newer, so the notice is the tag itself.
    try std.testing.expectEqualStrings("v0.2.0", newer("v0.1.14", .{ .tag = "v0.2.0", .at = day }).?);

    // The version running, and an older one, are both nothing to say. The
    // second is what a cache written before an upgrade looks like, so the
    // notice clears itself without anything having to invalidate it.
    try std.testing.expect(newer("v0.1.14", .{ .tag = "v0.1.14", .at = day }) == null);
    try std.testing.expect(newer("v0.1.14", .{ .tag = "v0.1.13", .at = day }) == null);

    // Nothing learned yet, and a lookup that failed, which keeps its time but
    // has no tag to show.
    try std.testing.expect(newer("v0.1.14", null) == null);
    try std.testing.expect(newer("v0.1.14", .{ .tag = "", .at = day }) == null);

    // A build from source has no version to compare, so it is never nagged.
    try std.testing.expect(newer("dev", .{ .tag = "v0.2.0", .at = day }) == null);
}
