//! Persistent, cross-shell command history. Commands are appended to a single
//! newline-delimited file at an absolute, cwd-independent path, so recording a
//! command from any directory always lands in the one shared store — the store
//! never depends on (or litters) the current working directory. Each line is
//! `<unix-seconds>\t<escaped directory>\t<escaped command>`; the directory the
//! command ran in is recorded so the picker can scope the list to it. The read
//! side deduplicates per (directory, command) — most-recent occurrence wins —
//! and returns entries newest-first to feed the picker.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

/// Upper bound on how much history is read into memory at once. Far more than a
/// realistic shell history, so it only ever bounds a corrupt or runaway file.
const read_limit: Io.Limit = .limited(4 << 20);

/// A stored command, the directory it ran in (empty when unknown, e.g. a
/// legacy line), and when it was last run (unix seconds; 0 when unknown).
pub const Entry = struct {
    command: []const u8,
    cwd: []const u8 = "",
    timestamp: i64,
};

/// Appends `command` (run in directory `cwd` at unix time `now`) to the
/// history file at absolute `path`. Surrounding whitespace is trimmed and
/// empty commands are dropped; a `cwd` that is empty or not absolute is
/// recorded as unknown. An advisory exclusive lock serializes concurrent
/// writers from other shells so appends from two terminals can never
/// interleave into one corrupt line.
///
/// A command that starts with a space or tab is not recorded at all — the
/// long-standing shell convention for "keep this one out of history", and the
/// only way to keep a secret typed on the command line out of the store.
pub fn add(io: Io, arena: Allocator, path: []const u8, command: []const u8, cwd: []const u8, now: i64) !void {
    if (isIgnored(command)) return;

    const trimmed = std.mem.trim(u8, command, " \t\r\n");
    if (trimmed.len == 0) return;

    if (std.fs.path.dirname(path)) |dir| {
        Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        };
    }

    const cmd = try escape(arena, trimmed);
    const line = if (cwd.len > 0 and cwd[0] == '/')
        try std.fmt.allocPrint(arena, "{d}\t{s}\t{s}\n", .{ now, try escape(arena, cwd), cmd })
    else
        try std.fmt.allocPrint(arena, "{d}\t{s}\n", .{ now, cmd });

    var file = try Dir.createFileAbsolute(io, path, .{ .truncate = false, .lock = .exclusive, .permissions = .fromMode(0o600) });
    defer file.close(io);

    // Command lines routinely hold paths and secrets, so the store must stay
    // owner-only; re-assert it on every append so files created by older
    // versions (world-readable) converge too.
    file.setPermissions(io, .fromMode(0o600)) catch {};

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

/// True when the command opts out of being recorded by starting with a space or
/// tab. Checked before any trimming, which would otherwise erase the marker.
fn isIgnored(command: []const u8) bool {
    return command.len > 0 and (command[0] == ' ' or command[0] == '\t');
}

test "a leading space keeps a command out of the store" {
    try std.testing.expect(isIgnored(" curl -H 'Authorization: Bearer sk-secret' https://api"));
    try std.testing.expect(isIgnored("\tsecret"));
    try std.testing.expect(!isIgnored("git status"));
    try std.testing.expect(!isIgnored(""));
    // Trailing whitespace is not an opt-out; only the first byte counts.
    try std.testing.expect(!isIgnored("git status "));
}

/// Splits raw file bytes into unique (directory, command) entries, most-recent
/// occurrence winning, ordered newest first. Walks lines back-to-front so the
/// first sighting of a pair is its latest one (and carries that occurrence's
/// timestamp). The same command run in two directories stays two entries, so
/// each directory keeps its own recency.
fn dedupe(arena: Allocator, bytes: []const u8) ![]const Entry {
    // One line is at most one entry, so counting them sizes both containers
    // exactly once. Letting them grow instead costs more than half the time
    // spent here, in rehashing and in arena copies that can never grow in
    // place — the keys allocated between them keep the list from being last.
    const lines = std.mem.count(u8, bytes, "\n") + 1;

    var seen: std.StringHashMap(void) = .init(arena);
    try seen.ensureTotalCapacity(std.math.lossyCast(u32, lines));
    var out: std.ArrayList(Entry) = .empty;
    try out.ensureTotalCapacity(arena, lines);

    var it = std.mem.splitBackwardsScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const entry = try parse(arena, line);
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ entry.cwd, entry.command });
        if (seen.contains(key)) continue;
        seen.putAssumeCapacity(key, {});
        out.appendAssumeCapacity(entry);
    }

    return out.toOwnedSlice(arena);
}

/// Parses one stored line into an `Entry`. A `<ts>\t<cwd>\t<command>` line
/// yields all three; the directory field is recognized by its leading `/`,
/// since an escaped absolute path always starts with one. A legacy
/// `<ts>\t<command>` line becomes a command with an unknown directory, a line
/// with no tab a command with an unknown (0) timestamp, and an unparseable
/// timestamp degrades the same way. (A legacy command that both starts with
/// `/` and contains a raw tab misparses; tabs are escaped going forward.)
fn parse(arena: Allocator, line: []const u8) Allocator.Error!Entry {
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse
        return .{ .command = try unescape(arena, line), .timestamp = 0 };

    const timestamp = std.fmt.parseInt(i64, line[0..tab], 10) catch 0;
    const rest = line[tab + 1 ..];

    if (rest.len > 0 and rest[0] == '/') {
        if (std.mem.indexOfScalar(u8, rest, '\t')) |cwd_tab| {
            return .{
                .command = try unescape(arena, rest[cwd_tab + 1 ..]),
                .cwd = try unescape(arena, rest[0..cwd_tab]),
                .timestamp = timestamp,
            };
        }
    }

    return .{ .command = try unescape(arena, rest), .timestamp = timestamp };
}

/// Escapes a field for single-line, tab-delimited storage: `\` then newline or
/// tab, so a multi-line command round-trips through a newline-delimited file
/// and an embedded tab can never split the line into extra fields.
fn escape(arena: Allocator, cmd: []const u8) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (cmd) |c| {
        switch (c) {
            '\\' => try out.appendSlice(arena, "\\\\"),
            '\n' => try out.appendSlice(arena, "\\n"),
            '\t' => try out.appendSlice(arena, "\\t"),
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
            't' => try out.append(arena, '\t'),
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

test "escape/unescape round-trips newlines, tabs, and backslashes" {
    try expectRoundTrip("git status");
    try expectRoundTrip("echo 'a\nb'");
    try expectRoundTrip("printf '\\\\n'");
    try expectRoundTrip("grep '\t' file");
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
    try std.testing.expectEqualStrings("", got[0].cwd);
    try std.testing.expectEqual(@as(i64, 0), got[0].timestamp);
}

test "parse reads the directory column and degrades on legacy lines" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const v2 = try parse(a, "30\t/home/davy/dev\tzig build");
    try std.testing.expectEqualStrings("zig build", v2.command);
    try std.testing.expectEqualStrings("/home/davy/dev", v2.cwd);
    try std.testing.expectEqual(@as(i64, 30), v2.timestamp);

    // A legacy command containing a raw tab stays one command, because its
    // first field does not look like an absolute path.
    const legacy = try parse(a, "5\tfoo\tbar");
    try std.testing.expectEqualStrings("foo\tbar", legacy.command);
    try std.testing.expectEqualStrings("", legacy.cwd);
}

test "dedupe keeps the same command per directory" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const got = try dedupe(arena.allocator(), "10\t/a\tzig build\n20\t/b\tzig build\n30\t/a\tzig build\n");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("/a", got[0].cwd);
    try std.testing.expectEqual(@as(i64, 30), got[0].timestamp);
    try std.testing.expectEqualStrings("/b", got[1].cwd);
}

test "storePath prefers XDG_DATA_HOME then HOME" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expectEqualStrings("/x/whetuu/history", (try storePath(a, "/x", "/home/davy")).?);
    try std.testing.expectEqualStrings("/home/davy/.local/share/whetuu/history", (try storePath(a, "", "/home/davy")).?);
    try std.testing.expect((try storePath(a, "", "")) == null);
}
