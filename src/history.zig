//! Persistent, cross-shell command history. Commands are appended to a single
//! newline-delimited file at an absolute, cwd-independent path, so recording a
//! command from any directory always lands in the one shared store — the store
//! never depends on (or litters) the current working directory. Each line is
//! `<unix-seconds>\t<escaped command>`. The read side deduplicates (most-recent
//! occurrence wins) and returns entries newest-first to feed the picker.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

/// Upper bound on how much history is read into memory at once. Far more than a
/// realistic shell history, so it only ever bounds a corrupt or runaway file.
const read_limit: Io.Limit = .limited(4 << 20);

/// A stored command and when it was last run (unix seconds; 0 when unknown, e.g.
/// a legacy line written before timestamps existed).
pub const Entry = struct {
    command: []const u8,
    timestamp: i64,
};

/// Appends `command` (run at unix time `now`) to the history file at absolute
/// `path`. Surrounding whitespace is trimmed and empty commands are dropped. An
/// advisory exclusive lock serializes concurrent writers from other shells so
/// appends from two terminals can never interleave into one corrupt line.
pub fn add(io: Io, arena: Allocator, path: []const u8, command: []const u8, now: i64) !void {
    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return;

    if (std.fs.path.dirname(path)) |dir| {
        Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const line = try std.fmt.allocPrint(arena, "{d}\t{s}\n", .{ now, try escape(arena, trimmed) });

    var file = try Dir.createFileAbsolute(io, path, .{ .truncate = false, .lock = .exclusive });
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    writer.pos = try file.length(io);
    try writer.interface.writeAll(line);
    try writer.interface.flush();
}

/// Reads the history file and returns its unique entries, newest first. A
/// missing file yields an empty slice, since "no history yet" is not an error.
pub fn load(io: Io, arena: Allocator, path: []const u8) ![]const Entry {
    const bytes = Dir.cwd().readFileAlloc(io, path, arena, read_limit) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };

    return dedupe(arena, bytes);
}

/// Absolute path of the history store: `$XDG_DATA_HOME/whetuu/history`, else
/// `$HOME/.local/share/whetuu/history`. Returns null when neither variable is
/// set, since there is then nowhere cwd-independent and safe to write.
pub fn storePath(arena: Allocator, xdg_data_home: []const u8, home: []const u8) Allocator.Error!?[]const u8 {
    if (xdg_data_home.len > 0) return try std.fmt.allocPrint(arena, "{s}/whetuu/history", .{xdg_data_home});

    if (home.len > 0) return try std.fmt.allocPrint(arena, "{s}/.local/share/whetuu/history", .{home});

    return null;
}

/// Splits raw file bytes into unique entries, most-recent occurrence winning,
/// ordered newest first. Walks lines back-to-front so the first sighting of a
/// command is its latest one (and carries that occurrence's timestamp).
fn dedupe(arena: Allocator, bytes: []const u8) ![]const Entry {
    var seen: std.StringHashMap(void) = .init(arena);
    var out: std.ArrayList(Entry) = .empty;

    var it = std.mem.splitBackwardsScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;

        const entry = try parse(arena, line);
        if (seen.contains(entry.command)) continue;

        try seen.put(entry.command, {});
        try out.append(arena, entry);
    }

    return out.toOwnedSlice(arena);
}

/// Parses one stored line into an `Entry`. A `<timestamp>\t<command>` line
/// yields both; a legacy line with no tab is treated as a command with an
/// unknown (0) timestamp, and an unparseable timestamp degrades the same way.
fn parse(arena: Allocator, line: []const u8) Allocator.Error!Entry {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse
        return .{ .command = try unescape(arena, line), .timestamp = 0 };

    const timestamp = std.fmt.parseInt(i64, line[0..tab], 10) catch 0;
    return .{ .command = try unescape(arena, line[tab + 1 ..]), .timestamp = timestamp };
}

/// Escapes a command for single-line storage: `\` then newline, so a multi-line
/// command round-trips through a newline-delimited file.
fn escape(arena: Allocator, cmd: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cmd) |c| {
        switch (c) {
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            else => try out.append(arena, c),
        }
    }

    return out.toOwnedSlice(arena);
}

/// Inverse of `escape`. Returns the input untouched (no allocation) when it
/// holds no escapes, which is the overwhelmingly common case.
fn unescape(arena: Allocator, line: []const u8) Allocator.Error![]const u8 {
    if (std.mem.indexOfScalar(u8, line, '\\') == null) return line;

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        if (line[i] != '\\' or i + 1 >= line.len) {
            try out.append(arena, line[i]);
            continue;
        }

        i += 1;
        switch (line[i]) {
            'n' => try out.append(arena, '\n'),
            else => try out.append(arena, line[i]),
        }
    }

    return out.toOwnedSlice(arena);
}

/// Runs a store round-trip against a throwaway arena.
fn expectRoundTrip(cmd: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const escaped = try escape(a, cmd);
    const back = try unescape(a, escaped);
    try std.testing.expectEqualStrings(cmd, back);
}

test "escape/unescape round-trips newlines and backslashes" {
    try expectRoundTrip("git status");
    try expectRoundTrip("echo 'a\nb'");
    try expectRoundTrip("printf '\\\\n'");
}

test "dedupe keeps the most recent occurrence and its timestamp, newest first" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const got = try dedupe(arena.allocator(), "10\ta\n20\tb\n30\ta\n40\tc\n");
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqualStrings("c", got[0].command);
    try std.testing.expectEqual(@as(i64, 40), got[0].timestamp);
    try std.testing.expectEqualStrings("a", got[1].command);
    try std.testing.expectEqual(@as(i64, 30), got[1].timestamp);
    try std.testing.expectEqualStrings("b", got[2].command);
}

test "dedupe reads legacy lines without a timestamp" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const got = try dedupe(arena.allocator(), "git status\n");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("git status", got[0].command);
    try std.testing.expectEqual(@as(i64, 0), got[0].timestamp);
}

test "storePath prefers XDG_DATA_HOME then HOME" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expectEqualStrings("/x/whetuu/history", (try storePath(a, "/x", "/home/davy")).?);
    try std.testing.expectEqualStrings("/home/davy/.local/share/whetuu/history", (try storePath(a, "", "/home/davy")).?);
    try std.testing.expect((try storePath(a, "", "")) == null);
}
