//! Async render orchestrator. Spawns the slowest segment module via `Io.async`
//! and runs the rest on the main thread while it is in flight, so the output is
//! deterministic even though the work overlaps. The character is pure and is
//! rendered synchronously after the segment line.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Writer = std.Io.Writer;

const Env = @import("Env.zig");
const Span = @import("style.zig").Span;
const character = @import("module_character.zig");
const cmd_duration = @import("module_cmd_duration.zig");
const directory = @import("module_directory.zig");
const git = @import("module_git.zig");
const language = @import("module_language.zig");
const style = @import("style.zig");
const user_host = @import("module_user_host.zig");

/// Written between adjacent visible segments: a light grey dot, padded so it
/// breathes between the colored segments on either side.
const separator: Span = .{ .style = .{ .color = .bright_black }, .text = " · " };

/// Renders the full status line to `w`. Git is spawned before anything else
/// runs, so its I/O overlaps every other module; writing in display order keeps
/// layout stable whatever finishes first. The language module runs detection
/// exactly once — its result also tints the character, which is pure and
/// rendered synchronously after the segment line.
pub fn render(io: Io, arena: Allocator, env: *const Env, w: *Writer) Writer.Error!void {
    // Git is the only module worth a task. It is far and away the slowest, and
    // the main thread has nothing else to do but wait for it, so everything
    // else runs here rather than paying to start a second thread — a thread
    // costs more than the language module it would carry.
    var git_future = io.async(git.run, .{ io, arena, env });

    var wrote_any = false;
    try writeSegment(w, env.shell, user_host.run(arena, env), &wrote_any);
    try writeSegment(w, env.shell, directory.run(io, arena, env), &wrote_any);

    // Detected before the wait so it overlaps git, written after it so the
    // segments stay in display order.
    const lang_result = language.run(io, arena, env);
    try writeSegment(w, env.shell, git_future.await(io), &wrote_any);
    try writeSegment(w, env.shell, lang_result.spans, &wrote_any);
    try writeSegment(w, env.shell, cmd_duration.run(io, arena, env), &wrote_any);

    // The character always appears, on its own line, with a trailing space so
    // the cursor sits one column clear of the symbol.
    try w.writeByte('\n');
    const ch = character.choose(lang_result.lang, env.exit_status);
    try style.write(w, env.shell, ch.style, ch.text);
    try w.writeByte(' ');
}

/// Writes one segment's spans, preceded by the separator when a previous
/// segment is already on the line. Null or empty spans write nothing.
fn writeSegment(w: *Writer, shell: Env.Shell, spans_opt: ?[]const Span, wrote_any: *bool) Writer.Error!void {
    const spans = spans_opt orelse return;
    if (spans.len == 0) return;

    if (wrote_any.*) try style.write(w, shell, separator.style, separator.text);
    for (spans) |span| try style.write(w, shell, span.style, span.text);
    wrote_any.* = true;
}

test "segments keep display order however the work overlaps" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try tmp.dir.writeFile(io, .{ .sub_path = "build.zig", .data = "" });

    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd = path_buf[0..try tmp.dir.realPathFile(io, ".", &path_buf)];

    const env: Env = .{
        .shell = .fish,
        .cwd = cwd,
        .home = "/nonexistent-home",
        .width = 200,
        .duration_ms = 0,
        .exit_status = 0,
    };

    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try render(io, arena.allocator(), &env, &w);
    const out = w.buffered();

    // Language is detected before git is awaited so the two overlap, and it is a
    // separate module from the one that writes it. Detecting early must not
    // write early: the directory still comes first, and the language logo after
    // whatever git had to say.
    const dir_at = std.mem.indexOf(u8, out, std.fs.path.basename(cwd)).?;
    const lang_at = std.mem.indexOf(u8, out, language.detect(io, cwd).?.icon).?;
    try std.testing.expect(dir_at < lang_at);

    // A checkout puts the temporary directory inside a repository, so the git
    // segment sits between the two. A build from a tarball has no repository and
    // no segment, and the order above is the whole assertion.
    if (std.mem.indexOf(u8, out, style.icon.branch)) |git_at| {
        try std.testing.expect(dir_at < git_at and git_at < lang_at);
    }
}

test "render emits the directory, a newline, then the trailing character" {
    var threaded: Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // cwd "/" carries no git repo or language markers, so only the directory
    // segment and the character are deterministic across machines.
    const env: Env = .{
        .shell = .fish,
        .cwd = "/",
        .home = "/nonexistent-home",
        .width = 80,
        .duration_ms = 0,
        .exit_status = 0,
    };

    var buf: [4096]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try render(io, arena.allocator(), &env, &w);

    const out = w.buffered();
    const newline = std.mem.indexOfScalar(u8, out, '\n').?;
    try std.testing.expect(std.mem.indexOf(u8, out[0..newline], "/") != null);
    try std.testing.expect(std.mem.indexOf(u8, out[newline..], style.icon.star) != null);
    try std.testing.expect(std.mem.endsWith(u8, out, " "));
}
