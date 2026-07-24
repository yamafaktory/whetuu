//! Memoises toolchain version strings across renders.
//!
//! Probing a toolchain costs a `fork`+`exec` — around 6 ms of a 9 ms render on
//! a warm machine — to read a string that changes when you upgrade and at no
//! other time. Entries are keyed on the resolved executable's path, mtime and
//! size, so an upgrade invalidates its own entry and nothing else has to.
//!
//! Every failure path here is silent: a missing, unreadable or corrupt cache
//! just means the caller probes as it always did. The cache is an optimisation,
//! never a source of truth.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Dir = Io.Dir;

/// Generous bound for the whole file — one short line per toolchain ever used.
const read_limit: std.Io.Limit = .limited(64 * 1024);

/// Identity of a resolved executable. Two probes of the same `path` with the
/// same `mtime` and `size` are assumed to yield the same version.
pub const Key = struct {
    path: []const u8,
    mtime: i96,
    size: u64,
};

/// Absolute path of the cache file: `$XDG_CACHE_HOME/whetuu/versions`, else
/// `$HOME/.cache/whetuu/versions`. Null when neither variable is set.
pub fn path(arena: Allocator, xdg_cache_home: []const u8, home: []const u8) Allocator.Error!?[]const u8 {
    if (xdg_cache_home.len > 0) return try std.fmt.allocPrint(arena, "{s}/whetuu/versions", .{xdg_cache_home});
    if (home.len > 0) return try std.fmt.allocPrint(arena, "{s}/.cache/whetuu/versions", .{home});
    return null;
}

/// Finds `exe` on `path_env` and stats it. Null when it is not on the PATH at
/// all, in which case the caller's probe would fail too.
pub fn resolve(io: Io, arena: Allocator, path_env: []const u8, exe: []const u8) ?Key {
    if (std.mem.indexOfScalar(u8, exe, '/') != null) return stat(io, exe);

    var it = std.mem.splitScalar(u8, path_env, ':');
    while (it.next()) |dir| {
        if (dir.len == 0) continue;
        const candidate = std.fs.path.join(arena, &.{ dir, exe }) catch return null;
        if (stat(io, candidate)) |key| return key;
    }

    return null;
}

fn stat(io: Io, abs_path: []const u8) ?Key {
    const file = Dir.openFileAbsolute(io, abs_path, .{}) catch return null;
    defer file.close(io);

    const info = file.stat(io) catch return null;
    if (info.kind != .file) return null;

    return .{ .path = abs_path, .mtime = info.mtime.nanoseconds, .size = info.size };
}

/// The cached version for `name`, or null on any miss: no file, no entry, or an
/// entry whose executable has changed since it was written.
pub fn get(io: Io, arena: Allocator, cache_path: []const u8, name: []const u8, key: Key) ?[]const u8 {
    const bytes = Dir.cwd().readFileAlloc(io, cache_path, arena, read_limit) catch return null;

    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        const entry = parse(line) orelse continue;
        if (!std.mem.eql(u8, entry.name, name)) continue;
        if (!std.mem.eql(u8, entry.key.path, key.path)) return null;
        if (entry.key.mtime != key.mtime or entry.key.size != key.size) return null;
        return entry.version;
    }

    return null;
}

/// Records `version` for `name`, replacing any previous entry. Written to a
/// temporary file and renamed, so a render reading the cache never observes a
/// half-written file — several shells may render at once.
pub fn put(
    io: Io,
    arena: Allocator,
    cache_path: []const u8,
    name: []const u8,
    key: Key,
    version: []const u8,
) void {
    if (std.mem.indexOfAny(u8, version, "\t\n") != null) return;

    const dir = std.fs.path.dirname(cache_path) orelse return;
    Dir.cwd().createDirPath(io, dir) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return,
    };

    var out: std.ArrayList(u8) = .empty;
    const existing = Dir.cwd().readFileAlloc(io, cache_path, arena, read_limit) catch "";
    var lines = std.mem.splitScalar(u8, existing, '\n');
    while (lines.next()) |line| {
        const entry = parse(line) orelse continue;
        if (std.mem.eql(u8, entry.name, name)) continue;
        out.print(arena, "{s}\n", .{line}) catch return;
    }
    out.print(arena, "{s}\t{s}\t{d}\t{d}\t{s}\n", .{ name, key.path, key.mtime, key.size, version }) catch return;

    const tmp = std.fmt.allocPrint(arena, "{s}.tmp", .{cache_path}) catch return;
    writeAll(io, tmp, out.items) catch return;
    Dir.renameAbsolute(tmp, cache_path, io) catch return;
}

fn writeAll(io: Io, abs_path: []const u8, bytes: []const u8) !void {
    var file = try Dir.createFileAbsolute(io, abs_path, .{ .permissions = .fromMode(0o600) });
    defer file.close(io);

    var buf: [1024]u8 = undefined;
    var writer = file.writer(io, &buf);
    try writer.interface.writeAll(bytes);
    try writer.interface.flush();
}

const Entry = struct {
    name: []const u8,
    key: Key,
    version: []const u8,
};

/// `name \t path \t mtime \t size \t version`. Null for blank or malformed
/// lines, which are simply dropped.
fn parse(line: []const u8) ?Entry {
    var it = std.mem.splitScalar(u8, line, '\t');
    const name = it.next() orelse return null;
    const exe = it.next() orelse return null;
    const mtime = it.next() orelse return null;
    const size = it.next() orelse return null;
    const version = it.next() orelse return null;
    if (name.len == 0 or version.len == 0) return null;

    return .{
        .name = name,
        .key = .{
            .path = exe,
            .mtime = std.fmt.parseInt(i96, mtime, 10) catch return null,
            .size = std.fmt.parseInt(u64, size, 10) catch return null,
        },
        .version = version,
    };
}

test "path prefers XDG_CACHE_HOME then HOME" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expectEqualStrings("/c/whetuu/versions", (try path(a, "/c", "/home/davy")).?);
    try std.testing.expectEqualStrings("/home/davy/.cache/whetuu/versions", (try path(a, "", "/home/davy")).?);
    try std.testing.expect((try path(a, "", "")) == null);
}

test "parse round-trips a well-formed line" {
    const entry = parse("zig\t/usr/bin/zig\t123\t456\t0.17.0").?;
    try std.testing.expectEqualStrings("zig", entry.name);
    try std.testing.expectEqualStrings("/usr/bin/zig", entry.key.path);
    try std.testing.expectEqual(@as(i96, 123), entry.key.mtime);
    try std.testing.expectEqual(@as(u64, 456), entry.key.size);
    try std.testing.expectEqualStrings("0.17.0", entry.version);
}

test "parse rejects malformed lines" {
    try std.testing.expect(parse("") == null);
    try std.testing.expect(parse("zig") == null);
    try std.testing.expect(parse("zig\t/usr/bin/zig\t123\t456") == null);
    try std.testing.expect(parse("zig\t/usr/bin/zig\tnot-a-number\t456\t0.17.0") == null);
    try std.testing.expect(parse("\t/usr/bin/zig\t1\t2\t0.17.0") == null);
}
