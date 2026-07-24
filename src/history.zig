//! Persistent, cross-shell command history. Commands are appended to a single
//! newline-delimited file at an absolute, cwd-independent path, so recording a
//! command from any directory always lands in the one shared store — the store
//! never depends on (or litters) the current working directory. Each line is
//! `<unix-seconds>\t<escaped directory>\t<escaped command>`; the directory the
//! command ran in is recorded so the picker can scope the list to it. The read
//! side deduplicates per (directory, command) — most-recent occurrence wins —
//! and returns entries newest-first to feed the picker.
//!
//! Appends are unbounded; reads are not. A load takes the last `read_budget`
//! bytes, so opening the picker costs the same on a store of any size. The file
//! keeps everything ever written either way — the window decides what is
//! offered, never what is kept.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Dir = std.Io.Dir;
const Io = std.Io;

/// How much of the store a load reads, taken from the end. This bounds what an
/// open costs without bounding what the store keeps: a larger file still holds
/// every line, and only the oldest stop being offered to the picker. At a
/// typical line length that is on the order of fifty thousand distinct
/// commands, which is years of them, and the picker opens in the same few
/// milliseconds either side of it.
const read_budget = 4 << 20;

/// A stored command, the directory it ran in (empty when unknown, e.g. a
/// legacy line), and when it was last run (unix seconds; 0 when unknown).
pub const Entry = struct {
    command: []const u8,
    cwd: []const u8 = "",
    timestamp: i64,
    /// A display-only marker for the ephemeral command that just failed, which
    /// the picker shows at the top and marks but never stores. The read path
    /// never sets it, so a loaded entry is always false.
    failed: bool = false,
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
    var file = Dir.openFileAbsolute(io, path, .{}) catch |err| switch (err) {
        error.FileNotFound => return &.{},
        else => return err,
    };
    defer file.close(io);

    const size = file.length(io) catch return &.{};
    if (size == 0) return &.{};

    // Read from the end, so what a big store loses is its oldest commands
    // rather than its newest. Under the budget this is the whole file and the
    // window is exact.
    const want: usize = @intCast(@min(@as(u64, read_budget), size));
    const start = size - want;

    const buf = try arena.alloc(u8, want);
    var reader = file.reader(io, buf);
    reader.seekTo(start) catch return &.{};
    const bytes = reader.interface.peek(want) catch return &.{};

    // Starting mid-file lands mid-record, and half a command is worse than no
    // command. A record can never hold a raw newline (`escape` rewrites it), so
    // the first separator is exactly where the first whole record begins.
    const whole = if (start == 0) bytes else bytes[(std.mem.indexOfScalar(u8, bytes, '\n') orelse return &.{}) + 1 ..];

    return dedupe(arena, whole);
}

/// Feeds whole records to the deduper, newest first, keeping the first sighting
/// of each pair.
fn collect(arena: Allocator, bytes: []const u8, unique: *Deduper, out: *std.ArrayList(Entry)) !void {
    var it = std.mem.splitBackwardsScalar(u8, bytes, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        const entry = try parse(arena, line);
        if (unique.seen(entry)) continue;
        out.appendAssumeCapacity(entry);
    }
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

/// Remembers which (directory, command) pairs a load has already offered, so
/// only the most recent occurrence of each survives.
///
/// The pair is hashed where it lies rather than joined into one key first.
/// Joining cost an allocation and a copy for every line in the store, on the
/// path that runs before the picker can draw anything.
const Deduper = struct {
    const Map = std.HashMap(Entry, void, Context, std.hash_map.default_max_load_percentage);

    const Context = struct {
        pub fn hash(_: Context, entry: Entry) u64 {
            var h: std.hash.Wyhash = .init(0);
            h.update(entry.cwd);
            // Without a separator "ab" + "c" and "a" + "bc" hash alike, which
            // would drop one of two genuinely different entries.
            h.update(&.{0});
            h.update(entry.command);
            return h.final();
        }

        pub fn eql(_: Context, a: Entry, b: Entry) bool {
            return std.mem.eql(u8, a.cwd, b.cwd) and std.mem.eql(u8, a.command, b.command);
        }
    };

    map: Map,

    fn init(arena: Allocator) Deduper {
        return .{ .map = .init(arena) };
    }

    /// Whether this pair has been offered already, recording it when not.
    /// Assumes the caller sized the map for every line it will be shown.
    fn seen(dedup: *Deduper, entry: Entry) bool {
        return dedup.map.getOrPutAssumeCapacity(entry).found_existing;
    }
};

/// Splits raw file bytes into unique (directory, command) entries, most-recent
/// occurrence winning, ordered newest first. Walks lines back-to-front so the
/// first sighting of a pair is its latest one (and carries that occurrence's
/// timestamp). The same command run in two directories stays two entries, so
/// each directory keeps its own recency.
fn dedupe(arena: Allocator, bytes: []const u8) ![]const Entry {
    // One line is at most one entry, so counting them sizes both containers
    // exactly once. Letting them grow instead costs more than half the time
    // spent here, in rehashing and in arena copies that can never grow in
    // place.
    const lines = std.mem.count(u8, bytes, "\n") + 1;

    var unique: Deduper = .init(arena);
    try unique.map.ensureTotalCapacity(std.math.lossyCast(u32, lines));
    var out: std.ArrayList(Entry) = .empty;
    try out.ensureTotalCapacity(arena, lines);

    try collect(arena, bytes, &unique, &out);
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

test "the pair hash separates the directory from the command" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Without a separator between the two fields these two lines hash alike,
    // and the second would be dropped as a duplicate of the first.
    const got = try dedupe(arena.allocator(), "10\t/ab\tc\n20\t/a\tbc\n");
    try std.testing.expectEqual(@as(usize, 2), got.len);
}

test "load returns the same entries as reading the whole file at once" {
    const io = std.testing.io;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Every command distinct, so a record lost or torn changes the count.
    const count = 20_000;
    var raw: std.ArrayList(u8) = .empty;
    for (0..count) |i| {
        try raw.print(a, "{d}\t/dev/whetuu\tgit commit -m \"change number {d}\"\n", .{ 1_700_000_000 + i, i });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "history", .data = raw.items });

    const path = try tmp.dir.realPathFileAlloc(io, "history", a);
    const got = try load(io, a, path);

    // Same entries, same order as reading the whole file in one go.
    const want = try dedupe(a, raw.items);
    try std.testing.expectEqual(want.len, got.len);
    for (want, got) |w, g| {
        try std.testing.expectEqualStrings(w.command, g.command);
        try std.testing.expectEqualStrings(w.cwd, g.cwd);
        try std.testing.expectEqual(w.timestamp, g.timestamp);
    }

    // Newest first, and nothing torn at either end of the file.
    try std.testing.expectEqualStrings("git commit -m \"change number 19999\"", got[0].command);
    try std.testing.expectEqualStrings("git commit -m \"change number 0\"", got[got.len - 1].command);
}

test "a store past the read budget keeps its newest commands" {
    const io = std.testing.io;

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var raw: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (raw.items.len < read_budget + (1 << 20)) : (i += 1) {
        try raw.print(a, "{d}\t/dev/whetuu\tcommand number {d}\n", .{ 1_700_000_000 + i, i });
    }
    try tmp.dir.writeFile(io, .{ .sub_path = "history", .data = raw.items });

    const path = try tmp.dir.realPathFileAlloc(io, "history", a);
    const got = try load(io, a, path);

    // Bounded by the window, not by the file.
    try std.testing.expect(got.len > 0);
    try std.testing.expect(got.len < i);

    // The window drops the oldest and never the newest, so the entry the
    // picker opens on is still the last command run.
    const newest = try std.fmt.allocPrint(a, "command number {d}", .{i - 1});
    try std.testing.expectEqualStrings(newest, got[0].command);

    // And what survives is whole, never a command cut in half by the window.
    for (got) |entry| {
        try std.testing.expect(std.mem.startsWith(u8, entry.command, "command number "));
        try std.testing.expectEqualStrings("/dev/whetuu", entry.cwd);
        try std.testing.expect(entry.timestamp >= 1_700_000_000);
    }
}

test "storePath prefers XDG_DATA_HOME then HOME" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expectEqualStrings("/x/whetuu/history", (try storePath(a, "/x", "/home/davy")).?);
    try std.testing.expectEqualStrings("/home/davy/.local/share/whetuu/history", (try storePath(a, "", "/home/davy")).?);
    try std.testing.expect((try storePath(a, "", "")) == null);
}
