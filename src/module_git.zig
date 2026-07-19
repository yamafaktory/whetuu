//! Git module. A single `git status --porcelain=2 --branch -z` call yields both
//! the branch and the working-tree status, which are rendered as adjacent spans
//! (magenta branch, then a colored status group). The call is bounded by a short
//! timeout so a slow or huge repository can never stall the prompt.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

const Env = @import("Env.zig");
const Span = @import("style.zig").Span;
const style = @import("style.zig");

/// Upper bound on the git call. A repo slower than this simply shows no git
/// segment rather than blocking the shell.
const timeout_ms = 250;

/// The shared branch glyph shown before the branch name.
const branch_icon = style.icon.branch;

/// Aggregated working-tree state parsed from porcelain v2 output. `branch` is
/// borrowed from the raw git output, so it lives as long as that buffer.
const GitInfo = struct {
    branch: []const u8 = "",
    detached: bool = false,
    conflicts: u32 = 0,
    staged: u32 = 0,
    modified: u32 = 0,
    untracked: u32 = 0,
    ahead: u32 = 0,
    behind: u32 = 0,
};

/// Renders the git segment, or null when not in a repo (or git is unavailable,
/// times out, or output cannot be allocated).
pub fn run(io: Io, arena: Allocator, env: *const Env) ?[]const Span {
    const raw = gitStatus(io, arena, env.cwd) orelse return null;
    const info = parse(raw);

    // Branch span (glyph + name), plus an optional status group after a space.
    var spans: std.ArrayList(Span) = .empty;
    const name = if (info.detached) "(detached)" else info.branch;
    const branch = std.fmt.allocPrint(arena, "{s} {s}", .{ branch_icon, name }) catch return null;
    spans.append(arena, .{ .style = .{ .bold = true, .color = .magenta }, .text = branch }) catch return null;

    if (statusText(arena, info) catch null) |text| {
        const color: style.Color = if (info.conflicts > 0) .red else .yellow;
        spans.append(arena, .{ .text = " " }) catch return null;
        spans.append(arena, .{ .style = .{ .color = color }, .text = text }) catch return null;
    }

    return spans.toOwnedSlice(arena) catch null;
}

/// Runs git and returns its stdout, or null on any failure (not a repo, missing
/// git, timeout). Uses `-C cwd` to be explicit about which tree is inspected.
fn gitStatus(io: Io, arena: Allocator, cwd: []const u8) ?[]const u8 {
    const argv = &[_][]const u8{ "git", "-C", cwd, "status", "--porcelain=2", "--branch", "-z" };
    const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } };

    const result = std.process.run(arena, io, .{ .argv = argv, .timeout = timeout }) catch return null;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    return result.stdout;
}

/// Parses porcelain v2 (`-z`) output. Records are NUL-separated; rename/copy
/// ("2") records are followed by an extra NUL-terminated source path that must
/// be skipped.
fn parse(raw: []const u8) GitInfo {
    var info: GitInfo = .{};

    var it = std.mem.splitScalar(u8, raw, 0);
    while (it.next()) |tok| {
        if (tok.len == 0) continue;
        switch (tok[0]) {
            '#' => parseHeader(tok, &info),
            '1' => countChange(tok, &info),
            '2' => {
                countChange(tok, &info);
                _ = it.next(); // discard the rename/copy source path
            },
            'u' => info.conflicts += 1,
            '?' => info.untracked += 1,
            else => {}, // '!' (ignored) and anything unexpected
        }
    }

    return info;
}

/// Parses a `# branch.*` header line into `info`.
fn parseHeader(tok: []const u8, info: *GitInfo) void {
    var parts = std.mem.tokenizeScalar(u8, tok, ' ');
    _ = parts.next(); // "#"
    const key = parts.next() orelse return;

    if (std.mem.eql(u8, key, "branch.head")) {
        const name = parts.next() orelse return;
        if (std.mem.eql(u8, name, "(detached)")) {
            info.detached = true;
        } else {
            info.branch = name;
        }
        return;
    }

    if (std.mem.eql(u8, key, "branch.ab")) {
        info.ahead = parseCount(parts.next() orelse return);
        info.behind = parseCount(parts.next() orelse return);
    }
}

/// Counts staged/unstaged changes from a "1"/"2" record's XY field at bytes 2–3.
fn countChange(tok: []const u8, info: *GitInfo) void {
    if (tok.len < 4) return;
    if (tok[2] != '.') info.staged += 1;
    if (tok[3] != '.') info.modified += 1;
}

/// Parses a signed count token like "+3" or "-2" into its magnitude.
fn parseCount(tok: []const u8) u32 {
    if (tok.len < 2) return 0;
    return std.fmt.parseInt(u32, tok[1..], 10) catch 0;
}

/// Builds the bracketed status string (e.g. `[+2 !1 ⇡1]`), or null when the
/// tree is clean and in sync (nothing to show).
fn statusText(arena: Allocator, info: GitInfo) Allocator.Error!?[]const u8 {
    var buf: [128]u8 = undefined;
    var w: Writer = .fixed(&buf);

    // A 128-byte buffer cannot overflow for these short markers, so a write
    // failure is impossible here; treat it as "nothing to show" defensively.
    writeMarkers(&w, info) catch return null;

    const out = w.buffered();
    if (out.len <= 2) return null; // only "[]"

    return try arena.dupe(u8, out);
}

/// Writes the status markers between brackets in a fixed priority order, one
/// space between groups so the counts read as separate facts.
fn writeMarkers(w: *Writer, info: GitInfo) Writer.Error!void {
    const markers = [_]struct { symbol: []const u8, count: u32 }{
        .{ .symbol = "=", .count = info.conflicts },
        .{ .symbol = "+", .count = info.staged },
        .{ .symbol = "!", .count = info.modified },
        .{ .symbol = "?", .count = info.untracked },
        .{ .symbol = "⇡", .count = info.ahead },
        .{ .symbol = "⇣", .count = info.behind },
    };

    try w.writeByte('[');

    var first = true;
    for (markers) |marker| {
        if (marker.count == 0) continue;
        if (!first) try w.writeByte(' ');
        try w.print("{s}{d}", .{ marker.symbol, marker.count });
        first = false;
    }

    try w.writeByte(']');
}

test "parses branch, ahead/behind, and changes" {
    // NUL-separated porcelain v2: branch headers, one staged+modified file, one
    // untracked file.
    const raw = "# branch.oid abc123\x00# branch.head main\x00# branch.ab +2 -1\x00" ++
        "1 MM N... 100644 100644 100644 aaa bbb file.zig\x00" ++
        "? new.txt\x00";
    const info = parse(raw);

    try std.testing.expectEqualStrings("main", info.branch);
    try std.testing.expectEqual(@as(u32, 2), info.ahead);
    try std.testing.expectEqual(@as(u32, 1), info.behind);
    try std.testing.expectEqual(@as(u32, 1), info.staged);
    try std.testing.expectEqual(@as(u32, 1), info.modified);
    try std.testing.expectEqual(@as(u32, 1), info.untracked);
    try std.testing.expect(!info.detached);
}

test "rename record skips its source path" {
    // A "2" record is followed by an extra NUL-terminated path; the parser must
    // not mistake that path for a new record.
    const raw = "# branch.head main\x00" ++
        "2 R. N... 100644 100644 100644 aaa bbb R100 new.zig\x00old.zig\x00" ++
        "? untracked.txt\x00";
    const info = parse(raw);

    try std.testing.expectEqual(@as(u32, 1), info.staged);
    try std.testing.expectEqual(@as(u32, 1), info.untracked);
}

test "detached head is flagged" {
    const info = parse("# branch.head (detached)\x00");
    try std.testing.expect(info.detached);
    try std.testing.expectEqualStrings("", info.branch);
}

test "status text omits empty groups and orders markers" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const info: GitInfo = .{ .staged = 2, .modified = 1, .ahead = 3 };
    const text = (try statusText(arena.allocator(), info)).?;
    try std.testing.expectEqualStrings("[+2 !1 ⇡3]", text);
}

test "clean in-sync tree shows no status" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expect((try statusText(arena.allocator(), .{})) == null);
}
