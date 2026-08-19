//! The newest published release: looking it up, and remembering the answer.
//!
//! `whetuu upgrade` asks for the tag to install a release, and `whetuu upgrade
//! --check` asks for the same tag to write it down, so the status line can say
//! a newer version exists without ever touching the network itself. A render
//! has milliseconds, and a round trip to GitHub has none of them.
//!
//! The answer lives in one small file next to the version cache, holding the
//! tag and the time it was learned. Nothing else is written, and nothing about
//! you is sent: the lookup is a GET of a public URL.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Version = std.SemanticVersion;
const Writer = std.Io.Writer;

const build_options = @import("build_options");

pub const repo = "yamafaktory/whetuu";

/// GitHub answers an API request that carries no User-Agent with 403.
const user_agent = "whetuu/" ++ build_options.version;

/// How long a looked-up tag is trusted before whetuu asks again. A release is
/// not urgent, and this is the whole cost of the notice: one request a day per
/// machine, whatever the number of shells or prompts.
pub const ttl_seconds: i64 = 24 * 60 * 60;

/// A tag, and when it was learned. An empty `tag` is a lookup that failed:
/// the time still counts, so an unreachable GitHub is asked once a day rather
/// than at every prompt.
pub const Checked = struct {
    tag: []const u8,
    at: i64,
};

/// Absolute path of the cache file, written into `buf`:
/// `$XDG_CACHE_HOME/whetuu/release`, else `$HOME/.cache/whetuu/release`. Null
/// when neither variable is set, which is also what turns the check off
/// entirely — with nowhere to write the answer there is no point asking the
/// question.
///
/// Takes a buffer rather than an allocator because the status line calls this
/// on every render, and an arena that has to grow costs an mmap to answer a
/// question a stack buffer answers for nothing.
pub fn cachePath(buf: []u8, xdg_cache_home: []const u8, home: []const u8) ?[]const u8 {
    if (xdg_cache_home.len > 0) return std.fmt.bufPrint(buf, "{s}/whetuu/release", .{xdg_cache_home}) catch null;
    if (home.len > 0) return std.fmt.bufPrint(buf, "{s}/.cache/whetuu/release", .{home}) catch null;
    return null;
}

/// Enough for the cache path on any sane system, and for the one line in it.
pub const path_buf_len = std.fs.max_path_bytes;
pub const line_buf_len = 128;

/// Reads the remembered tag into `buf`, or null on any miss: no file, no read,
/// a line this version does not understand. Every failure here just means "ask
/// again". The result borrows `buf`, which is a `line_buf_len` array on the
/// caller's stack — the file holds one short line, and a render should not have
/// to allocate to read it.
pub fn readCache(io: Io, path: []const u8, buf: []u8) ?Checked {
    const bytes = Io.Dir.cwd().readFile(io, path, buf) catch return null;
    const line = std.mem.sliceTo(bytes, '\n');

    var fields = std.mem.splitScalar(u8, line, '\t');
    const tag = fields.next() orelse return null;
    const at = std.fmt.parseInt(i64, fields.next() orelse return null, 10) catch return null;
    return .{ .tag = tag, .at = at };
}

/// Writes the remembered tag, and reports whether it landed. The caller stamps
/// the time before starting a lookup, so a directory that refuses the write
/// says so once rather than being retried at every prompt.
///
/// Staged beside the file and renamed, because several shells render at once
/// and none of them may read half a line.
pub fn writeCache(io: Io, path: []const u8, tag: []const u8, at: i64) bool {
    if (std.mem.indexOfAny(u8, tag, "\t\n") != null) return false;

    const dir_path = std.fs.path.dirname(path) orelse return false;
    Io.Dir.cwd().createDirPath(io, dir_path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return false,
    };

    var dir = Io.Dir.openDirAbsolute(io, dir_path, .{}) catch return false;
    defer dir.close(io);

    var staged = dir.createFileAtomic(io, std.fs.path.basename(path), .{
        .permissions = .fromMode(0o600),
        .replace = true,
    }) catch return false;
    defer staged.deinit(io);

    var buf: [128]u8 = undefined;
    var fw = staged.file.writer(io, &buf);
    fw.interface.print("{s}\t{d}\n", .{ tag, at }) catch return false;
    fw.interface.flush() catch return false;
    staged.replace(io) catch return false;
    return true;
}

/// Whether the remembered answer is old enough to look up again. A cache that
/// is not there at all is stale, and so is one stamped in the future, which is
/// what a clock moving backwards looks like.
pub fn isStale(cached: ?Checked, now: i64) bool {
    const c = cached orelse return true;
    return now < c.at or now - c.at >= ttl_seconds;
}

/// The tag of the newest published release. `/releases/latest` skips
/// prereleases, so a `v0.1.6-rc.1` never reaches anyone this way.
pub fn latestTag(io: Io, arena: Allocator, client: *std.http.Client) ?[]const u8 {
    const body = get(io, client, arena, "https://api.github.com/repos/" ++ repo ++ "/releases/latest") orelse return null;
    const Release = struct { tag_name: []const u8 };
    const release = std.json.parseFromSliceLeaky(Release, arena, body, .{ .ignore_unknown_fields = true }) catch {
        note(io, "could not read the release the GitHub API returned", .{});
        return null;
    };
    // Everything downstream builds a URL out of this or prints it. Parsing it
    // as `v` plus semver is what keeps it to characters both are safe with.
    if (version(release.tag_name) == null) {
        note(io, "the latest release is tagged {s}, which is not a version whetuu can compare", .{release.tag_name});
        return null;
    }
    return release.tag_name;
}

/// The body of a GET, or null when anything at all went wrong: no route, a
/// redirect loop, a 404, a body that would not fit in memory. The reason is
/// reported here, once, because every caller has its own answer to a failure —
/// a download stops an upgrade, a missing changelog does not, and a background
/// check has its output pointed at /dev/null anyway.
pub fn get(io: Io, client: *std.http.Client, arena: Allocator, url: []const u8) ?[]u8 {
    var body: Writer.Allocating = .init(arena);
    const result = client.fetch(.{
        .location = .{ .url = url },
        .headers = .{ .user_agent = .{ .override = user_agent } },
        .response_writer = &body.writer,
    }) catch |err| {
        note(io, "could not fetch {s}: {t}", .{ url, err });
        return null;
    };
    if (result.status != .ok) {
        note(io, "{s} returned {d} {s}", .{ url, @backingInt(result.status), result.status.phrase() orelse "" });
        return null;
    }
    return body.written();
}

/// A release tag as a version, or null when it is not one. Tags are `v` plus
/// semver, and a build from source reports `dev`, which is no version at all.
pub fn version(tag: []const u8) ?Version {
    if (!std.mem.startsWith(u8, tag, "v")) return null;
    return Version.parse(tag[1..]) catch null;
}

/// One line of detail on stderr, for a failure the caller reports in its own
/// words.
pub fn note(io: Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &buf);
    fw.interface.print("whetuu: " ++ fmt ++ "\n", args) catch {};
    fw.interface.flush() catch {};
}

test "a release tag is a version, and a source build is not" {
    try std.testing.expectEqual(@as(u64, 1), version("v0.1.14").?.minor);
    try std.testing.expectEqual(std.math.Order.gt, version("v0.2.0").?.order(version("v0.1.14").?));
    try std.testing.expect(version("dev") == null);
    try std.testing.expect(version("v1.2") == null);
    try std.testing.expect(version("0.1.14") == null);
}

test "the cache remembers a tag and the time it was learned" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [std.fs.max_path_bytes]u8 = undefined;
    const dir_path = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    var path_buf: [path_buf_len]u8 = undefined;
    const path = cachePath(&path_buf, dir_path, "").?;
    var line_buf: [line_buf_len]u8 = undefined;

    // Nothing written yet, so there is nothing to trust and every reader agrees
    // it is time to ask.
    try std.testing.expect(readCache(io, path, &line_buf) == null);
    try std.testing.expect(isStale(null, 1_000));

    try std.testing.expect(writeCache(io, path, "v0.1.15", 1_000));
    const cached = readCache(io, path, &line_buf).?;
    try std.testing.expectEqualStrings("v0.1.15", cached.tag);
    try std.testing.expectEqual(@as(i64, 1_000), cached.at);

    // Trusted for a day, asked again after one, and asked again when the clock
    // has moved backwards under it.
    try std.testing.expect(!isStale(cached, 1_000 + ttl_seconds - 1));
    try std.testing.expect(isStale(cached, 1_000 + ttl_seconds));
    try std.testing.expect(isStale(cached, 999));

    // A lookup that failed keeps the time and drops the tag, which is what
    // stops a machine with no route to GitHub asking at every prompt.
    try std.testing.expect(writeCache(io, path, "", 2_000));
    const failed = readCache(io, path, &line_buf).?;
    try std.testing.expectEqualStrings("", failed.tag);
    try std.testing.expectEqual(@as(i64, 2_000), failed.at);
    try std.testing.expect(!isStale(failed, 2_000));
}
