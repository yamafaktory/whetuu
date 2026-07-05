//! Current-directory module. Collapses `$HOME` to `~`, then — when the path is
//! too wide for the terminal — keeps the leading anchor (`~` or `/root`) and as
//! many trailing components as fit, eliding the middle with `…`.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const Span = @import("style.zig").Span;
const style = @import("style.zig");

/// Column budget for the directory when the terminal width is unknown.
const default_budget: usize = 40;

/// Never squeeze the directory below this many columns, however narrow the
/// terminal claims to be.
const min_budget: usize = 20;

/// Renders the directory segment. Returns null only if allocation fails, since
/// a prompt should never abort over the directory.
pub fn run(io: std.Io, arena: Allocator, ctx: *const Context) ?[]const Span {
    _ = io;
    const text = format(arena, ctx.cwd, ctx.home, budgetForWidth(ctx.width)) catch return null;
    return style.single(arena, .{ .bold = true, .color = .cyan }, text) catch null;
}

/// The directory may claim up to half the line; the rest is left for the git,
/// language, and duration segments that share it. Falls back to a fixed budget
/// when the shell did not report a width.
fn budgetForWidth(cols: u16) usize {
    if (cols == 0) return default_budget;

    const half: usize = cols / 2;
    return @max(half, min_budget);
}

/// Column count of `text`, counting each codepoint as one column so the `…` and
/// any non-ASCII directory names are not overcounted by their byte length.
fn displayWidth(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Produces the displayed directory string, fitting it within `budget` columns.
/// Pure except for `arena`, so it is unit-tested directly.
fn format(arena: Allocator, cwd: []const u8, home: []const u8, budget: usize) Allocator.Error![]const u8 {
    const display = try collapseHome(arena, cwd, home);

    if (displayWidth(display) <= budget) return display;

    // Collect non-empty components; a pathologically deep path just shows in
    // full rather than risking a fixed-buffer overrun.
    var comps: [128][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, display, '/');
    while (it.next()) |c| {
        if (c.len == 0) continue;

        if (n == comps.len) return display;

        comps[n] = c;
        n += 1;
    }

    if (n <= 2) return display;

    const absolute = display[0] == '/';
    const anchor = comps[0];
    const anchor_w = @as(usize, if (absolute) 1 else 0) + displayWidth(anchor);

    // Keep the last component, then greedily reveal earlier ones — widening the
    // shown suffix toward the anchor — for as long as `anchor/…/suffix` fits.
    var kept: usize = n - 1;
    while (kept > 1) {
        const trial = kept - 1;

        var w = anchor_w + 2; // "/…"
        var i = trial;
        while (i < n) : (i += 1) w += 1 + displayWidth(comps[i]);

        if (w > budget) break;

        kept = trial;
    }

    // Everything after the anchor fits, so there is no middle to elide.
    if (kept == 1) return display;

    const tail = try std.mem.join(arena, "/", comps[kept..n]);
    if (absolute) return std.fmt.allocPrint(arena, "/{s}/…/{s}", .{ anchor, tail });

    return std.fmt.allocPrint(arena, "{s}/…/{s}", .{ anchor, tail });
}

/// Replaces a leading `$HOME` with `~`. Returns a borrowed slice when no change
/// is needed, otherwise an arena-allocated string.
fn collapseHome(arena: Allocator, cwd: []const u8, home: []const u8) Allocator.Error![]const u8 {
    if (home.len == 0) return cwd;

    if (std.mem.eql(u8, cwd, home)) return "~";

    const under_home = std.mem.startsWith(u8, cwd, home) and cwd.len > home.len and cwd[home.len] == '/';
    if (!under_home) return cwd;

    return std.fmt.allocPrint(arena, "~{s}", .{cwd[home.len..]});
}

/// Runs `format` against a throwaway arena, mirroring how production frees all
/// intermediate allocations at once.
fn expectFormat(expected: []const u8, cwd: []const u8, home: []const u8, budget: usize) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const got = try format(arena.allocator(), cwd, home, budget);
    try std.testing.expectEqualStrings(expected, got);
}

test "collapses home to tilde" {
    try expectFormat("~/dev/lsnav", "/home/davy/dev/lsnav", "/home/davy", default_budget);
}

test "exact home is just tilde" {
    try expectFormat("~", "/home/davy", "/home/davy", default_budget);
}

test "a path that fits is shown in full" {
    try expectFormat("~/a/b/c/d/e", "/home/davy/a/b/c/d/e", "/home/davy", default_budget);
}

test "a too-wide path keeps the anchor and greedily fills trailing dirs" {
    // Budget 8 fits "~/…/d/e" (7 cols) but not "~/…/c/d/e" (9 cols).
    try expectFormat("~/…/d/e", "/home/davy/a/b/c/d/e", "/home/davy", 8);
}

test "an extremely narrow budget keeps only the anchor and last dir" {
    try expectFormat("~/…/e", "/home/davy/a/b/c/d/e", "/home/davy", 5);
}

test "absolute path keeps its leading slash on both sides of the ellipsis" {
    try expectFormat("/usr/…/man/man1", "/usr/local/share/man/man1", "/home/davy", 16);
}

test "absolute path outside home shown in full when it fits" {
    try expectFormat("/usr/local/bin", "/usr/local/bin", "/home/davy", default_budget);
}

test "budget is half the terminal width, floored, with a fixed fallback" {
    try std.testing.expectEqual(default_budget, budgetForWidth(0));
    try std.testing.expectEqual(min_budget, budgetForWidth(10));
    try std.testing.expectEqual(@as(usize, 60), budgetForWidth(120));
}
