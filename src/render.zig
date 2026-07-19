//! Async render orchestrator. Spawns every segment module concurrently via
//! `Io.async`, then awaits them in display order so the output is deterministic
//! even though the work overlaps. The prompt character is pure and is rendered
//! synchronously after the segment line.

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

/// Written between adjacent visible segments: a light grey dot, padded so it
/// breathes between the colored segments on either side.
const separator: Span = .{ .style = .{ .color = .bright_black }, .text = " · " };

/// Renders the full prompt to `w`. All modules are spawned before any is
/// awaited, so their I/O overlaps; awaiting in display order keeps layout
/// stable. The language module runs detection exactly once — its result also
/// tints the prompt character, which is pure and rendered synchronously after
/// the segment line.
pub fn render(io: Io, arena: Allocator, env: *const Env, w: *Writer) Writer.Error!void {
    var directory_future = io.async(directory.run, .{ io, arena, env });
    var git_future = io.async(git.run, .{ io, arena, env });
    var language_future = io.async(language.run, .{ io, arena, env });
    var duration_future = io.async(cmd_duration.run, .{ io, arena, env });

    var wrote_any = false;
    try writeSegment(w, env.shell, directory_future.await(io), &wrote_any);
    try writeSegment(w, env.shell, git_future.await(io), &wrote_any);

    const lang_result = language_future.await(io);
    try writeSegment(w, env.shell, lang_result.spans, &wrote_any);
    try writeSegment(w, env.shell, duration_future.await(io), &wrote_any);

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
