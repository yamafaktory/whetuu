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
    /// Fallback version command, tried when `argv` yields nothing — for
    /// ecosystems where two toolchains share the same markers (OpenTofu and
    /// Terraform both own `*.tf`).
    argv_alt: ?[]const []const u8 = null,
    color: Rgb,
    icon: []const u8,
    markers: []const []const u8,
    name: []const u8,
};

/// Detection table, in priority order. The first language whose marker exists in
/// the current directory wins. A `*.ext` marker matches any file with that
/// extension; languages with only extension markers sit at the bottom so a
/// stray source file never outranks a real project manifest. Icons are Nerd
/// Font glyphs (codepoint in the comment) — swap any that render wrong in your
/// font. Colors are brand RGB.
const langs = [_]Lang{
    // nf-seti-zig (U+E6A9), Zig orange
    .{ .name = "zig", .icon = "\u{e6a9}", .color = .{ .r = 247, .g = 164, .b = 29 }, .markers = &.{"build.zig"}, .argv = &.{ "zig", "version" } },
    // nf-dev-rust (U+E7A8), Rust red-orange
    .{ .name = "rust", .icon = "\u{e7a8}", .color = .{ .r = 206, .g = 66, .b = 43 }, .markers = &.{"Cargo.toml"}, .argv = &.{ "rustc", "--version" } },
    // nf-seti-go (U+E627), Go cyan
    .{ .name = "go", .icon = "\u{e627}", .color = .{ .r = 0, .g = 173, .b = 216 }, .markers = &.{"go.mod"}, .argv = &.{ "go", "version" } },
    // nf-seti-typescript (U+E628), Deno green (before node: deno projects may also carry package.json)
    .{ .name = "deno", .icon = "\u{e628}", .color = .{ .r = 112, .g = 255, .b = 175 }, .markers = &.{ "deno.json", "deno.jsonc" }, .argv = &.{ "deno", "--version" } },
    // nf-dev-nodejs_small (U+E718), Node green
    .{ .name = "node", .icon = "\u{e718}", .color = .{ .r = 60, .g = 135, .b = 58 }, .markers = &.{"package.json"}, .argv = &.{ "node", "--version" } },
    // nf-dev-python (U+E73C), Python blue
    .{ .name = "python", .icon = "\u{e73c}", .color = .{ .r = 55, .g = 118, .b = 171 }, .markers = &.{ "pyproject.toml", "requirements.txt", "setup.py" }, .argv = &.{ "python3", "--version" } },
    // nf-dev-java (U+E738), Java orange
    .{ .name = "java", .icon = "\u{e738}", .color = .{ .r = 237, .g = 139, .b = 0 }, .markers = &.{ "pom.xml", "build.gradle" }, .argv = &.{ "java", "--version" } },
    // nf-custom-kotlin (U+E634), Kotlin violet
    .{ .name = "kotlin", .icon = "\u{e634}", .color = .{ .r = 127, .g = 82, .b = 255 }, .markers = &.{ "build.gradle.kts", "settings.gradle.kts" }, .argv = &.{ "kotlinc", "-version" } },
    // nf-dev-ruby (U+E739), Ruby red
    .{ .name = "ruby", .icon = "\u{e739}", .color = .{ .r = 204, .g = 52, .b = 45 }, .markers = &.{"Gemfile"}, .argv = &.{ "ruby", "--version" } },
    // nf-dev-php (U+E73D), PHP indigo
    .{ .name = "php", .icon = "\u{e73d}", .color = .{ .r = 119, .g = 123, .b = 180 }, .markers = &.{"composer.json"}, .argv = &.{ "php", "--version" } },
    // nf-dev-swift (U+E755), Swift orange
    .{ .name = "swift", .icon = "\u{e755}", .color = .{ .r = 240, .g = 81, .b = 56 }, .markers = &.{"Package.swift"}, .argv = &.{ "swift", "--version" } },
    // nf-custom-elixir (U+E62D), Elixir purple
    .{ .name = "elixir", .icon = "\u{e62d}", .color = .{ .r = 110, .g = 74, .b = 126 }, .markers = &.{"mix.exs"}, .argv = &.{ "elixir", "--version" } },
    // nf-dev-erlang (U+E7B1), Erlang red
    .{ .name = "erlang", .icon = "\u{e7b1}", .color = .{ .r = 169, .g = 5, .b = 51 }, .markers = &.{"rebar.config"}, .argv = &.{ "erl", "+V" } },
    // sparkle (U+2726), Gleam pink
    .{ .name = "gleam", .icon = "\u{2726}", .color = .{ .r = 255, .g = 175, .b = 243 }, .markers = &.{"gleam.toml"}, .argv = &.{ "gleam", "--version" } },
    // nf-dev-dart (U+E798), Dart blue
    .{ .name = "dart", .icon = "\u{e798}", .color = .{ .r = 1, .g = 117, .b = 194 }, .markers = &.{"pubspec.yaml"}, .argv = &.{ "dart", "--version" } },
    // nf-dev-scala (U+E737), Scala red
    .{ .name = "scala", .icon = "\u{e737}", .color = .{ .r = 220, .g = 50, .b = 47 }, .markers = &.{"build.sbt"}, .argv = &.{ "scala", "--version" } },
    // nf-seti-julia (U+E624), Julia purple
    .{ .name = "julia", .icon = "\u{e624}", .color = .{ .r = 149, .g = 88, .b = 178 }, .markers = &.{"Project.toml"}, .argv = &.{ "julia", "--version" } },
    // nf-dev-clojure (U+E768), Clojure blue
    .{ .name = "clojure", .icon = "\u{e768}", .color = .{ .r = 88, .g = 129, .b = 216 }, .markers = &.{ "deps.edn", "project.clj" }, .argv = &.{ "clojure", "--version" } },
    // nf-custom-elm (U+E62C), Elm light blue
    .{ .name = "elm", .icon = "\u{e62c}", .color = .{ .r = 96, .g = 181, .b = 204 }, .markers = &.{"elm.json"}, .argv = &.{ "elm", "--version" } },
    // nf-custom-crystal (U+E62F), neutral grey (brand black is unreadable on dark themes)
    .{ .name = "crystal", .icon = "\u{e62f}", .color = .{ .r = 170, .g = 170, .b = 170 }, .markers = &.{"shard.yml"}, .argv = &.{ "crystal", "--version" } },
    // plain V, V blue
    .{ .name = "v", .icon = "V", .color = .{ .r = 93, .g = 135, .b = 191 }, .markers = &.{"v.mod"}, .argv = &.{ "v", "version" } },
    // nf-dev-dlang (U+E7AF), D red
    .{ .name = "d", .icon = "\u{e7af}", .color = .{ .r = 176, .g = 57, .b = 49 }, .markers = &.{ "dub.json", "dub.sdl" }, .argv = &.{ "dmd", "--version" } },
    // nf-dev-haskell (U+E777), Haskell violet
    .{ .name = "haskell", .icon = "\u{e777}", .color = .{ .r = 93, .g = 79, .b = 133 }, .markers = &.{ "stack.yaml", "cabal.project", "*.cabal" }, .argv = &.{ "ghc", "--numeric-version" } },
    // nf-seti-ocaml (U+E67A), OCaml orange
    .{ .name = "ocaml", .icon = "\u{e67a}", .color = .{ .r = 236, .g = 104, .b = 19 }, .markers = &.{ "dune-project", "*.opam" }, .argv = &.{ "ocaml", "-version" } },
    // nf-md-language_csharp (U+F031B), .NET purple
    .{ .name = "c#", .icon = "\u{f031b}", .color = .{ .r = 81, .g = 43, .b = 212 }, .markers = &.{ "global.json", "*.csproj" }, .argv = &.{ "dotnet", "--version" } },
    // nf-dev-fsharp (U+E7A7), F# blue
    .{ .name = "f#", .icon = "\u{e7a7}", .color = .{ .r = 55, .g = 139, .b = 186 }, .markers = &.{"*.fsproj"}, .argv = &.{ "dotnet", "--version" } },
    // nf-seti-nim (U+E677), Nim yellow
    .{ .name = "nim", .icon = "\u{e677}", .color = .{ .r = 255, .g = 233, .b = 83 }, .markers = &.{"*.nimble"}, .argv = &.{ "nim", "--version" } },
    // nf-seti-lua (U+E620), Lua navy
    .{ .name = "lua", .icon = "\u{e620}", .color = .{ .r = 44, .g = 45, .b = 114 }, .markers = &.{ ".luarc.json", "*.rockspec" }, .argv = &.{ "lua", "-v" } },
    // nf-dev-perl (U+E769), Perl blue
    .{ .name = "perl", .icon = "\u{e769}", .color = .{ .r = 57, .g = 69, .b = 126 }, .markers = &.{ "cpanfile", "Makefile.PL" }, .argv = &.{ "perl", "-v" } },
    // nf-md-language_r (U+F07D4), R blue
    .{ .name = "r", .icon = "\u{f07d4}", .color = .{ .r = 39, .g = 109, .b = 195 }, .markers = &.{ ".Rprofile", "*.Rproj" }, .argv = &.{ "R", "--version" } },
    // lambda, Racket red
    .{ .name = "racket", .icon = "\u{03bb}", .color = .{ .r = 158, .g = 29, .b = 32 }, .markers = &.{ "info.rkt", "*.rkt" }, .argv = &.{ "racket", "--version" } },
    // lambda, Common Lisp green
    .{ .name = "lisp", .icon = "\u{03bb}", .color = .{ .r = 63, .g = 182, .b = 139 }, .markers = &.{"*.asd"}, .argv = &.{ "sbcl", "--version" } },
    // lambda, Scheme blue
    .{ .name = "scheme", .icon = "\u{03bb}", .color = .{ .r = 30, .g = 74, .b = 236 }, .markers = &.{"*.scm"}, .argv = &.{ "guile", "--version" } },
    // slashed O, Odin blue
    .{ .name = "odin", .icon = "\u{00d8}", .color = .{ .r = 56, .g = 130, .b = 210 }, .markers = &.{"*.odin"}, .argv = &.{ "odin", "version" } },
    // nf-md-terraform (U+F1062), Terraform purple; *.tf is shared with OpenTofu, so probe tofu first
    .{ .name = "terraform", .icon = "\u{f1062}", .color = .{ .r = 123, .g = 66, .b = 188 }, .markers = &.{"*.tf"}, .argv = &.{ "tofu", "--version" }, .argv_alt = &.{ "terraform", "--version" } },
    // nf-custom-cpp (U+E61D), C++ blue (before C: C++ projects often carry .c files too)
    .{ .name = "c++", .icon = "\u{e61d}", .color = .{ .r = 0, .g = 89, .b = 156 }, .markers = &.{ "*.cpp", "*.cc", "*.cxx" }, .argv = &.{ "c++", "--version" } },
    // nf-custom-c (U+E61E), C blue-grey
    .{ .name = "c", .icon = "\u{e61e}", .color = .{ .r = 168, .g = 185, .b = 204 }, .markers = &.{"*.c"}, .argv = &.{ "cc", "--version" } },
    // nf-linux-nixos (U+F313), Nix blue — infra markers sit below every real language
    .{ .name = "nix", .icon = "\u{f313}", .color = .{ .r = 82, .g = 119, .b = 195 }, .markers = &.{ "flake.nix", "default.nix", "shell.nix" }, .argv = &.{ "nix", "--version" } },
    // nf-dev-docker (U+E7B0), Docker blue
    .{ .name = "docker", .icon = "\u{e7b0}", .color = .{ .r = 36, .g = 150, .b = 237 }, .markers = &.{ "Dockerfile", "docker-compose.yml", "compose.yaml" }, .argv = &.{ "docker", "--version" } },
};

/// What one prompt render needs from this module: the segment spans plus the
/// detected language itself, so the prompt character can reuse the detection
/// instead of scanning the directory tree a second time.
pub const Result = struct {
    lang: ?Lang = null,
    spans: ?[]const Span = null,
};

/// Detects the project language and renders the segment (logo + version) in
/// one pass. `spans` is null when the directory matches no known language or
/// allocation fails.
pub fn run(io: Io, arena: Allocator, ctx: *const Context) Result {
    const lang = detect(io, ctx.cwd) orelse return .{};

    const text = label: {
        const version = probeAnyVersion(io, arena, lang) orelse
            break :label lang.icon;
        break :label std.fmt.allocPrint(arena, "{s} v{s}", .{ lang.icon, version }) catch return .{ .lang = lang };
    };

    return .{ .lang = lang, .spans = style.single(arena, .{ .rgb = lang.color }, text) catch null };
}

/// Returns the first language whose marker file exists in `cwd` or any of its
/// ancestors, so a project is detected anywhere inside its tree — not only at
/// the root. The nearest ancestor wins; ties within a directory follow `langs`
/// priority order.
pub fn detect(io: Io, cwd: []const u8) ?Lang {
    var dir: ?[]const u8 = cwd;
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        if (detectIn(io, d)) |lang| return lang;
    }

    return null;
}

/// A marker string paired with the table index of the language it belongs to.
const MarkerRef = struct { []const u8, usize };

/// Comptime map from every exact (non-wildcard) marker filename to its
/// language's table index — one hash lookup per directory entry instead of a
/// scan over the whole table.
const exact_markers = std.StaticStringMap(usize).initComptime(splitMarkers(false));

/// The few `*.ext` markers with their table index, in priority order, so the
/// first suffix hit is already the best wildcard candidate.
const wildcard_markers = splitMarkers(true);

/// Collects the table's markers into one flat comptime list — the wildcard
/// ones when `wildcard` is set, the exact filenames otherwise.
fn splitMarkers(comptime wildcard: bool) []const MarkerRef {
    comptime {
        var list: []const MarkerRef = &.{};
        for (langs, 0..) |lang, idx| {
            for (lang.markers) |marker| {
                if (std.mem.startsWith(u8, marker, "*.") != wildcard) continue;

                list = list ++ &[_]MarkerRef{.{ marker, idx }};
            }
        }

        return list;
    }
}

/// Scans one directory's entries in a single pass and returns the
/// highest-priority language with a matching marker, or null. Streaming the
/// listing once beats probing every marker individually now that the table
/// holds dozens of them, and it is what makes `*.ext` markers possible at all.
fn detectIn(io: Io, path: []const u8) ?Lang {
    var d = Io.Dir.openDirAbsolute(io, path, .{ .iterate = true }) catch return null;
    defer d.close(io);

    var best: usize = langs.len;
    var it = d.iterate();

    while (true) {
        const entry = (it.next(io) catch break) orelse break;
        const idx = markerIndex(entry.name) orelse continue;

        if (idx < best) best = idx;

        if (best == 0) break;
    }

    return if (best < langs.len) langs[best] else null;
}

/// Returns the lowest table index of any language whose marker matches
/// `name`, or null. Exact filenames resolve through the comptime map; the
/// short wildcard list is scanned only as far as it could still beat that.
fn markerIndex(name: []const u8) ?usize {
    const exact = exact_markers.get(name);

    for (wildcard_markers) |ref| {
        const marker, const idx = ref;
        if (exact != null and idx >= exact.?) break;

        if (markerMatches(marker, name)) return idx;
    }

    return exact;
}

/// True when `name` matches `marker`: exact equality, or — for a `*.ext`
/// marker — a non-empty stem followed by that extension.
fn markerMatches(marker: []const u8, name: []const u8) bool {
    if (!std.mem.startsWith(u8, marker, "*.")) return std.mem.eql(u8, marker, name);

    const ext = marker[1..];

    return name.len > ext.len and std.mem.endsWith(u8, name, ext);
}

/// Probes `lang.argv` and, when that yields nothing, `lang.argv_alt`. A
/// missing binary fails instantly, so the fallback adds no cost when only one
/// of the two toolchains is installed.
fn probeAnyVersion(io: Io, arena: Allocator, lang: Lang) ?[]const u8 {
    if (probeVersion(io, arena, lang.argv)) |version| return version;

    const alt = lang.argv_alt orelse return null;

    return probeVersion(io, arena, alt);
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

test "detect matches extension markers" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "main.odin", .data = "" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);

    const lang = detect(io, buf[0..len]);
    try std.testing.expectEqualStrings("odin", lang.?.name);
}

test "detect prefers a manifest over a stray source extension" {
    const io = std.testing.io;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "helper.c", .data = "" });
    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });

    var buf: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPathFile(io, ".", &buf);

    const lang = detect(io, buf[0..len]);
    try std.testing.expectEqualStrings("zig", lang.?.name);
}

test "markerMatches requires a stem before a wildcard extension" {
    try std.testing.expect(markerMatches("*.cabal", "app.cabal"));
    try std.testing.expect(!markerMatches("*.cabal", ".cabal"));
    try std.testing.expect(!markerMatches("*.c", "main.cpp"));
    try std.testing.expect(markerMatches("Cargo.toml", "Cargo.toml"));
    try std.testing.expect(!markerMatches("Cargo.toml", "NotCargo.toml"));
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
