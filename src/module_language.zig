//! Language module. Detects the project type from a marker file in the current
//! directory and shows the toolchain version. Detection is a cheap directory
//! probe; the version is fetched by running the toolchain with a short timeout,
//! falling back to just the language icon if that fails.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const Io = std.Io;
const Rgb = @import("style.zig").Rgb;
const Span = @import("style.zig").Span;
const style = @import("style.zig");

/// Upper bound on a version probe. Toolchains that are slow to report a version
/// simply show the bare language name instead.
const timeout_ms = 200;

/// A detectable language: the files that identify it, how to display it (Nerd
/// Font logo + brand color), and the command that prints its version.
pub const Lang = struct {
    argv: []const []const u8,
    color: Rgb,
    icon: []const u8,
    markers: []const []const u8,
    name: []const u8,
};

/// Detection table, in priority order. The first language whose marker exists in
/// the current directory wins. Icons are Nerd Font glyphs (codepoint in the
/// comment) — swap any that render wrong in your font. Colors are brand RGB.
const langs = [_]Lang{
    // nf-seti-zig (U+E6A9), Zig orange
    .{ .name = "zig", .icon = "\u{e6a9}", .color = .{ .r = 247, .g = 164, .b = 29 }, .markers = &.{"build.zig"}, .argv = &.{ "zig", "version" } },
    // nf-dev-rust (U+E7A8), Rust red-orange
    .{ .name = "rust", .icon = "\u{e7a8}", .color = .{ .r = 206, .g = 66, .b = 43 }, .markers = &.{"Cargo.toml"}, .argv = &.{ "rustc", "--version" } },
    // nf-dev-nodejs_small (U+E718), Node green
    .{ .name = "node", .icon = "\u{e718}", .color = .{ .r = 60, .g = 135, .b = 58 }, .markers = &.{"package.json"}, .argv = &.{ "node", "--version" } },
    // nf-dev-python (U+E73C), Python blue
    .{ .name = "python", .icon = "\u{e73c}", .color = .{ .r = 55, .g = 118, .b = 171 }, .markers = &.{ "pyproject.toml", "requirements.txt", "setup.py" }, .argv = &.{ "python3", "--version" } },
    // nf-seti-go (U+E627), Go cyan
    .{ .name = "go", .icon = "\u{e627}", .color = .{ .r = 0, .g = 173, .b = 216 }, .markers = &.{"go.mod"}, .argv = &.{ "go", "version" } },
};

/// Renders the language segment (logo + version), or null when the directory
/// matches no known language.
pub fn run(io: Io, arena: Allocator, ctx: *const Context) ?[]const Span {
    const lang = detect(io, ctx.cwd) orelse return null;

    const text = label: {
        const version = probeVersion(io, arena, lang.argv) orelse
            break :label lang.icon;
        break :label std.fmt.allocPrint(arena, "{s} v{s}", .{ lang.icon, version }) catch return null;
    };

    return style.single(arena, .{ .rgb = lang.color }, text) catch null;
}

/// Returns the first language whose marker file exists in `cwd` or any of its
/// ancestors, so a project is detected anywhere inside its tree — not only at
/// the root. The nearest ancestor wins; ties within a directory follow `langs`
/// priority order.
pub fn detect(io: Io, cwd: []const u8) ?Lang {
    const root = Io.Dir.cwd();
    var buf: [std.fs.max_path_bytes]u8 = undefined;

    var dir: ?[]const u8 = cwd;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        for (langs) |lang| {
            for (lang.markers) |marker| {
                const probe = std.fmt.bufPrint(&buf, "{s}/{s}", .{ d, marker }) catch continue;
                root.access(io, probe, .{}) catch continue;

                return lang;
            }
        }
    }

    return null;
}

/// Runs the toolchain's version command and extracts a version string from its
/// output. Returns null on any failure. The result borrows from arena-owned
/// process output, so it lives for the render.
fn probeVersion(io: Io, arena: Allocator, argv: []const []const u8) ?[]const u8 {
    const timeout: Io.Timeout = .{ .duration = .{ .raw = Io.Duration.fromMilliseconds(timeout_ms), .clock = .awake } };

    const result = std.process.run(arena, io, .{ .argv = argv, .timeout = timeout }) catch return null;
    switch (result.term) {
        .exited => |code| if (code != 0) return null,
        else => return null,
    }

    // Most toolchains print to stdout; fall back to stderr for the few that do not.
    const out = if (result.stdout.len > 0) result.stdout else result.stderr;
    return extractVersion(out);
}

/// Finds the first `major.minor[.patch]` run in `text`, ignoring any leading
/// `v` or surrounding words (e.g. "go version go1.22.0" → "1.22.0",
/// "v20.11.0" → "20.11.0").
fn extractVersion(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (!isDigit(text[i])) continue;

        const start = i;
        var dots: u8 = 0;
        var j = i;
        while (j < text.len) {
            if (isDigit(text[j])) {
                j += 1;
                continue;
            }

            const is_inner_dot = text[j] == '.' and dots < 2 and j + 1 < text.len and isDigit(text[j + 1]);
            if (!is_inner_dot) break;

            dots += 1;
            j += 1;
        }

        if (dots >= 1) return text[start..j];

        i = j; // skip this all-digit, dotless run
    }

    return null;
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

test "detect finds a marker in an ancestor directory" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });
    try tmp.dir.createDirPath(io, "a/b/c");

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, "a/b/c", &buf);

    const lang = detect(io, buf[0..len]);
    try std.testing.expect(lang != null);
    try std.testing.expectEqualStrings("zig", lang.?.name);
}

test "extracts plain semver" {
    try std.testing.expectEqualStrings("1.75.0", extractVersion("rustc 1.75.0 (82e1608df 2023-12-21)").?);
}

test "extracts node v-prefixed version" {
    try std.testing.expectEqualStrings("20.11.0", extractVersion("v20.11.0\n").?);
}

test "extracts go embedded version" {
    try std.testing.expectEqualStrings("1.22.0", extractVersion("go version go1.22.0 linux/amd64").?);
}

test "extracts zig dev version stem only" {
    try std.testing.expectEqualStrings("0.17.0", extractVersion("0.17.0-dev.242+5d55999d2").?);
}

test "no version present" {
    try std.testing.expect(extractVersion("no numbers here") == null);
    try std.testing.expect(extractVersion("build 242 only") == null);
}
