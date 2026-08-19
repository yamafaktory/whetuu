//! `whetuu upgrade`: replaces the running binary with the newest release.
//!
//! Every step happens in this process. The release is resolved through the
//! GitHub API, the tarball is downloaded over TLS, checked against the
//! published `SHA256SUMS`, and swapped in with a rename. Nothing shells out, so
//! the command works on a machine with no curl, wget or tar, which is what a
//! static binary is for. It does what `docs/install.sh` does, minus the shell
//! config, so a change to one belongs in the other.
//!
//! Resolving the release, and the cache behind the status line's notice, live
//! in `release.zig`, which the `--check` path here keeps up to date.

const builtin = @import("builtin");

const std = @import("std");
const Allocator = std.mem.Allocator;
const Environ = std.process.Environ;
const Io = std.Io;
const Sha256 = std.crypto.hash.sha2.Sha256;
const Writer = std.Io.Writer;

const build_options = @import("build_options");
const cli = @import("cli.zig");
const release = @import("release.zig");
const style = @import("style.zig");

const repo = release.repo;

/// The release asset built for this machine, null on a platform the release
/// workflow does not cross-compile for.
const target: ?[]const u8 = published(assetTarget(builtin.target.os.tag, builtin.target.cpu.arch));

/// The asset name for an os and a cpu. Derived rather than looked up in
/// `release_targets`, because "any Linux upgrades to the static musl build,
/// whatever this one was built against" is a decision that list does not
/// encode.
fn assetTarget(os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch) ?[]const u8 {
    return switch (os) {
        .linux => switch (arch) {
            .x86_64 => "x86_64-linux-musl",
            .aarch64 => "aarch64-linux-musl",
            else => null,
        },
        .macos => switch (arch) {
            .x86_64 => "x86_64-macos",
            .aarch64 => "aarch64-macos",
            else => null,
        },
        else => null,
    };
}

/// `triple` if `zig build release` publishes it, and a compile error if it does
/// not. `build.zig` hands its target list over, so dropping a target there
/// fails the build here instead of leaving a 404 for whoever runs `upgrade` on
/// that machine.
fn published(comptime triple: ?[]const u8) ?[]const u8 {
    const name = triple orelse return null;
    for (build_options.release_targets) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return name;
    }
    @compileError("upgrade would ask for " ++ name ++ ", which release_targets in build.zig does not publish");
}

/// Downloads the newest release and replaces the running binary with it, then
/// prints every changelog entry between the two versions.
///
/// With `--check` it stops after the changelog: it says what is waiting and
/// what changed in it, and installs nothing. That is also what the status line
/// starts for itself once a day, with its output on `/dev/null` — the tag it
/// writes down on the way through is what the notice is made of.
pub fn run(io: Io, arena: Allocator, environ: Environ, args: []const [:0]const u8) !void {
    const opts = cli.parseUpgrade(args) catch fail(
        io,
        "upgrade takes one flag, {s}--check{s}, and installs nothing with it.",
        .{ style.sgr.bold, style.sgr.reset },
    );

    var out_buf: [1024]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &out_buf);
    const out = &fw.interface;

    const current = release.version(build_options.version) orelse fail(
        io,
        "this binary reports version {s}, so there is no release to compare it with. Install a release, or pull and rebuild.",
        .{build_options.version},
    );
    // The client allocates from more than one thread, so it gets the same
    // thread-safe allocator the io implementation runs on rather than the arena.
    var client: std.http.Client = .{ .allocator = std.heap.smp_allocator, .io = io };
    defer client.deinit();

    // The tag is `v` plus semver or `latestTag` refuses it, which is what keeps
    // every URL built from it below to characters a URL is safe with.
    const tag = release.latestTag(io, arena, &client) orelse
        fail(io, "could not find the latest release. Nothing was changed.", .{});
    const latest = release.version(tag).?;

    // Written down whichever way this goes, so the status line stops saying a
    // release is waiting the moment one is installed, and the daily check has
    // nothing left to ask today.
    var path_buf: [release.path_buf_len]u8 = undefined;
    if (release.cachePath(&path_buf, envOrEmpty(environ, "XDG_CACHE_HOME"), envOrEmpty(environ, "HOME"))) |path| {
        _ = release.writeCache(io, path, tag, Io.Clock.now(.real, io).toSeconds());
    }

    switch (latest.order(current)) {
        .eq => {
            try out.print(star ++ " whetuu " ++ bold ++ "{s}" ++ reset ++ " is the newest release\n", .{build_options.version});
            return out.flush();
        },
        // A version stamped by hand, which `zig build release -Dversion=` makes
        // easy. Saying it is the newest release would be a lie.
        .lt => {
            try out.print(
                star ++ " whetuu " ++ bold ++ "{s}" ++ reset ++ " is ahead of the newest release, " ++ bold ++ "{s}" ++ reset ++ "\n",
                .{ build_options.version, tag },
            );
            return out.flush();
        },
        .gt => {},
    }

    if (opts.check) {
        try out.print(
            star ++ " whetuu " ++ purple ++ bold ++ "{s}" ++ reset ++ " is available. Run " ++
                purple ++ "whetuu upgrade" ++ reset ++ " to install it.\n",
            .{tag},
        );
        try out.flush();
        writeChangelog(io, &client, arena, out, tag, current) catch {};
        return out.flush();
    }

    const asset_target = target orelse fail(
        io,
        "no release is built for {t} {t}. Build from source instead.",
        .{ builtin.target.os.tag, builtin.target.cpu.arch },
    );

    // `/proc/self/exe` on Linux and `_NSGetExecutablePath` on macOS, both
    // resolved through their symlinks, so the upgrade lands on the binary
    // rather than on a link to it.
    const exe = std.process.executablePathAlloc(io, arena) catch fail(io, "could not find the running binary", .{});
    const dir_path = std.fs.path.dirname(exe) orelse fail(io, "the running binary has no directory: {s}", .{exe});
    // Checked before the download rather than after it, so a binary installed
    // somewhere only root can write fails in a second instead of a megabyte.
    Io.Dir.accessAbsolute(io, dir_path, .{ .write = true }) catch fail(
        io,
        "{s} is not writable, so this install cannot replace itself. Upgrade it the way you installed it.",
        .{dir_path},
    );
    const dir = Io.Dir.openDirAbsolute(io, dir_path, .{}) catch fail(io, "could not open {s}", .{dir_path});
    defer dir.close(io);

    try out.print(
        star ++ " upgrading whetuu " ++ bold ++ "{s}" ++ reset ++ " to " ++ purple ++ bold ++ "{s}" ++ reset ++ "\n\n",
        .{ build_options.version, tag },
    );
    try out.flush();

    const name = try std.fmt.allocPrint(arena, "whetuu-{s}-{s}.tar.gz", .{ tag, asset_target });
    const base = try std.fmt.allocPrint(arena, "https://github.com/" ++ repo ++ "/releases/download/{s}", .{tag});
    try step(out, "download", name);
    const tarball = release.get(io, &client, arena, try std.fmt.allocPrint(arena, "{s}/{s}", .{ base, name })) orelse
        fail(io, "the download failed. Nothing was changed.", .{});
    const sums = release.get(io, &client, arena, try std.fmt.allocPrint(arena, "{s}/SHA256SUMS", .{base})) orelse
        fail(io, "the checksums could not be downloaded. Nothing was changed.", .{});

    // Verified before anything is unpacked, so a bad download never reaches the
    // disk as a binary.
    const expected = listedSum(sums, name) orelse
        fail(io, "{s} is not listed in SHA256SUMS. Refusing to install.", .{name});
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(tarball, &digest, .{});
    if (!std.mem.eql(u8, &std.fmt.bytesToHex(digest, .lower), expected)) {
        fail(io, "checksum mismatch for {s}. Refusing to install.", .{name});
    }
    try step(out, "verify", "sha256 matches SHA256SUMS");

    install(io, arena, dir, std.fs.path.basename(exe), tarball) catch |err| switch (err) {
        error.BadArchive => fail(io, "could not unpack {s}. Nothing was changed.", .{name}),
        error.NoBinary => fail(io, "{s} holds no whetuu binary. Nothing was changed.", .{name}),
        error.WriteFailed => fail(io, "could not write the new binary to {s}", .{dir_path}),
        error.OutOfMemory => return err,
    };
    try step(out, "install", exe);
    try out.flush();

    writeChangelog(io, &client, arena, out, tag, current) catch {};
    try out.writeAll("\n" ++ dim ++
        "Running shells pick this up on their next command. Open a new one to\nreload the init script." ++
        reset ++ "\n");
    try out.flush();
}

/// One environment variable as a plain slice, empty when unset.
fn envOrEmpty(environ: Environ, key: []const u8) []const u8 {
    return environ.getPosix(key) orelse "";
}

/// The digest `SHA256SUMS` lists for `name`. The names in it carry a `./`
/// prefix, so it is stripped and the rest compared exactly rather than matched
/// as a pattern full of dots.
fn listedSum(sums: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.tokenizeAny(u8, sums, "\r\n");
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const sum = fields.next() orelse continue;
        const listed = fields.next() orelse continue;
        const bare = if (std.mem.startsWith(u8, listed, "./")) listed[2..] else listed;
        if (std.mem.eql(u8, bare, name)) return sum;
    }
    return null;
}

/// What `install` could not do. Each one is a different sentence to the person
/// running the upgrade, so `run` maps them rather than printing one message for
/// all three.
const InstallError = error{
    /// Not a gzipped tar, or it ended early.
    BadArchive,
    /// It unpacked, and held no `whetuu`.
    NoBinary,
    /// The directory took the write no further.
    WriteFailed,
} || Allocator.Error;

/// Unpacks the `whetuu` entry of `tarball` over `basename` in `dir`.
///
/// The bytes land in a temporary file beside the target and are renamed onto
/// it, which is the only way to replace a binary that is about to run: writing
/// into the running file is refused outright, and a copy that stops halfway
/// would leave a truncated whetuu on `PATH` for every status line to run. A
/// rename within one directory cannot be seen half done, and a process already
/// running the old binary keeps it.
///
/// Nothing is written until an entry named `whetuu` is found, so an archive
/// this does not understand leaves the binary that is running in place.
fn install(io: Io, arena: Allocator, dir: Io.Dir, basename: []const u8, tarball: []const u8) InstallError!void {
    var gzip: Io.Reader = .fixed(tarball);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var decompress: std.compress.flate.Decompress = .init(&gzip, .gzip, window);
    var it: std.tar.Iterator = .init(&decompress.reader, .{
        .file_name_buffer = try arena.alloc(u8, std.fs.max_path_bytes),
        .link_name_buffer = try arena.alloc(u8, std.fs.max_path_bytes),
    });

    while (it.next() catch return error.BadArchive) |entry| {
        if (entry.kind != .file or !std.mem.eql(u8, std.fs.path.basename(entry.name), "whetuu")) continue;

        var staged = dir.createFileAtomic(io, basename, .{ .permissions = .executable_file, .replace = true }) catch
            return error.WriteFailed;
        defer staged.deinit(io);

        var fw = staged.file.writer(io, try arena.alloc(u8, 64 * 1024));
        it.streamRemaining(entry, &fw.interface) catch return error.BadArchive;
        fw.interface.flush() catch return error.WriteFailed;
        // A binary the shell runs on every command is worth the sync: the
        // rename can otherwise outlive the bytes across a power cut and leave
        // an empty file where whetuu was.
        staged.file.sync(io) catch {};
        staged.replace(io) catch return error.WriteFailed;
        return;
    }

    return error.NoBinary;
}

/// Prints every changelog entry between `from` and `tag`, read from the
/// `CHANGELOG.md` of the new tag.
///
/// The binary is already replaced by the time this runs, so a failure here
/// prints where to read the notes instead and the upgrade still stands.
fn writeChangelog(io: Io, client: *std.http.Client, arena: Allocator, out: *Writer, tag: []const u8, from: std.SemanticVersion) !void {
    const url = try std.fmt.allocPrint(arena, "https://raw.githubusercontent.com/" ++ repo ++ "/{s}/CHANGELOG.md", .{tag});
    const markdown = release.get(io, client, arena, url) orelse {
        try out.print(
            "\n" ++ dim ++ "Release notes: https://github.com/" ++ repo ++ "/releases/tag/{s}" ++ reset ++ "\n",
            .{tag},
        );
        return;
    };
    try writeEntries(arena, out, markdown, from);
}

/// Renders the `CHANGELOG.md` sections newer than `from`, newest first, and
/// stops at the version that was running. Written for a terminal rather than a
/// renderer: the version heading is the release, the one below it is the kind
/// of change, and everything else is an entry.
///
/// The text arrives over the network, so every line goes through `sanitize`
/// before it reaches the terminal, exactly as a branch name does.
fn writeEntries(arena: Allocator, out: *Writer, markdown: []const u8, from: std.SemanticVersion) !void {
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    var printing = false;
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "## ")) {
            const heading = line[3..];
            const released = release.version(std.mem.sliceTo(heading, ' ')) orelse {
                // An unreleased section, which a tagged changelog never holds.
                printing = false;
                continue;
            };
            if (released.order(from) != .gt) return;
            printing = true;
            try out.print("\n" ++ purple ++ bold ++ "{s}" ++ reset ++ "\n", .{try style.sanitize(arena, heading)});
            continue;
        }
        if (!printing) continue;

        const text = try style.sanitize(arena, line);
        if (std.mem.startsWith(u8, text, "### ")) {
            try out.print("\n  " ++ bold ++ "{s}" ++ reset ++ "\n", .{text[4..]});
        } else if (std.mem.startsWith(u8, text, "- ")) {
            try out.print("  " ++ dim ++ "-" ++ reset ++ " {s}\n", .{text[2..]});
        }
    }
}

/// One `<label>  <value>` row of progress, flushed as it happens: the whole
/// point of the line is that it is on screen while the step it names runs.
fn step(out: *Writer, label: []const u8, value: []const u8) !void {
    try out.print("  " ++ dim ++ "{s: <10}" ++ reset ++ "{s}\n", .{ label, value });
    try out.flush();
}

/// Stops the upgrade with one line on stderr. Every caller reaches this before
/// the new binary is renamed into place, so nothing is half installed.
fn fail(io: Io, comptime fmt: []const u8, args: anytype) noreturn {
    release.note(io, fmt, args);
    std.process.exit(1);
}

const bold = style.sgr.bold;
const dim = style.sgr.dim;
const purple = style.sgr.fg_purple;
const reset = style.sgr.reset;
const star = purple ++ style.icon.star ++ reset;

test "the asset names and the published targets are the same set" {
    const machines = [_]struct { os: std.Target.Os.Tag, arch: std.Target.Cpu.Arch }{
        .{ .os = .linux, .arch = .x86_64 },
        .{ .os = .linux, .arch = .aarch64 },
        .{ .os = .macos, .arch = .x86_64 },
        .{ .os = .macos, .arch = .aarch64 },
    };

    // Everything a machine can be mapped to is published. The compile error in
    // `published` covers the machine running this, and this covers the rest.
    var names: [machines.len][]const u8 = undefined;
    for (machines, &names) |machine, *name| {
        name.* = assetTarget(machine.os, machine.arch) orelse return error.UnmappedMachine;
        for (build_options.release_targets) |candidate| {
            if (std.mem.eql(u8, candidate, name.*)) break;
        } else return error.NotPublished;
    }

    // And everything published can be reached by some machine, so a target
    // added to `build.zig` alone fails here rather than shipping a tarball
    // nothing ever asks for.
    for (build_options.release_targets) |triple| {
        for (names) |name| {
            if (std.mem.eql(u8, triple, name)) break;
        } else return error.Unreachable;
    }

    // A platform with no build gets no asset name, which is what stops the
    // upgrade before it asks.
    try std.testing.expect(assetTarget(.windows, .x86_64) == null);
    try std.testing.expect(assetTarget(.linux, .riscv64) == null);
}

test "the checksum is read for the exact asset name" {
    const sums =
        \\aaa  ./whetuu-v0.1.15-aarch64-macos.tar.gz
        \\bbb  ./whetuu-v0.1.15-x86_64-linux-musl.tar.gz
        \\ccc  whetuu-v0.1.15-x86_64-macos.tar.gz
        \\
    ;

    // The `./` prefix the release workflow writes is stripped, and a name it
    // does not list is not silently matched by a neighbour.
    try std.testing.expectEqualStrings("bbb", listedSum(sums, "whetuu-v0.1.15-x86_64-linux-musl.tar.gz").?);
    try std.testing.expectEqualStrings("ccc", listedSum(sums, "whetuu-v0.1.15-x86_64-macos.tar.gz").?);
    try std.testing.expect(listedSum(sums, "whetuu-v0.1.15-aarch64-linux-musl.tar.gz") == null);
    try std.testing.expect(listedSum(sums, "macos.tar.gz") == null);
    try std.testing.expect(listedSum("", "whetuu-v0.1.15-x86_64-macos.tar.gz") == null);
}

test "the changelog stops at the version that was running" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const markdown =
        \\# Changelog
        \\
        \\Never edited by hand.
        \\
        \\## v0.1.16 — 2026-08-21
        \\
        \\### Added
        \\
        \\- Upgrade in place
        \\
        \\## v0.1.15 — 2026-08-20
        \\
        \\### Fixed
        \\
        \\- Stop dropping the last row
        \\
        \\## v0.1.14 — 2026-08-19
        \\
        \\### Changed
        \\
        \\- Something you already have
        \\
    ;

    var out: Writer.Allocating = .init(arena);
    try writeEntries(arena, &out.writer, markdown, release.version("v0.1.14").?);
    const text = out.written();

    // Both newer releases, and neither the preamble nor the version already
    // installed.
    try std.testing.expect(std.mem.indexOf(u8, text, "v0.1.16 — 2026-08-21") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Upgrade in place") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Stop dropping the last row") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "v0.1.14") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Something you already have") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Never edited by hand") == null);
}

test "a changelog entry cannot repaint the terminal" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();

    const markdown = "## v0.1.15 — 2026\n\n### Changed\n\n- Take \x1b[2J back\n";

    var out: Writer.Allocating = .init(arena);
    try writeEntries(arena, &out.writer, markdown, release.version("v0.1.14").?);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "Take ?[2J back") != null);
}

/// A gzipped tar holding one file, which is the shape `zig build release`
/// publishes and the only shape `install` is asked to read.
fn testTarball(arena: Allocator, name: []const u8, bytes: []const u8) ![]u8 {
    var archive: Writer.Allocating = try .initCapacity(arena, 1024);
    var compress: std.compress.flate.Compress = try .init(
        &archive.writer,
        try arena.alloc(u8, std.compress.flate.max_window_len),
        .gzip,
        .fastest,
    );
    var tar: std.tar.Writer = .{ .underlying_writer = &compress.writer };
    try tar.writeFileBytes(name, bytes, .{ .mode = 0o755 });
    try tar.finishPedantically();
    try compress.finish();
    return archive.written();
}

test "install swaps the binary for the one in the archive" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "whetuu", .data = "the old binary", .flags = .{ .permissions = .executable_file } });

    const tarball = try testTarball(arena, "whetuu", "the new binary");
    try install(io, arena, tmp.dir, "whetuu", tarball);

    const installed = try tmp.dir.readFileAlloc(io, "whetuu", arena, .unlimited);
    try std.testing.expectEqualStrings("the new binary", installed);

    // Renamed onto the old file rather than written into it, and still a file
    // the shell can run.
    const stat = try tmp.dir.statFile(io, "whetuu", .{});
    try std.testing.expect(stat.permissions.toMode() & 0o100 != 0);
}

test "install leaves the running binary alone when the archive is not one" {
    var arena_instance: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena_instance.deinit();
    const arena = arena_instance.allocator();
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "whetuu", .data = "the old binary", .flags = .{ .permissions = .executable_file } });

    // A tarball of something else, and bytes that are no tarball at all. The
    // upgrade stops on both, and the binary that is running survives each.
    const wrong = try testTarball(arena, "README.md", "not a binary");
    try std.testing.expectError(error.NoBinary, install(io, arena, tmp.dir, "whetuu", wrong));
    try std.testing.expectError(error.BadArchive, install(io, arena, tmp.dir, "whetuu", "certainly not a gzip"));

    const kept = try tmp.dir.readFileAlloc(io, "whetuu", arena, .unlimited);
    try std.testing.expectEqualStrings("the old binary", kept);
}
