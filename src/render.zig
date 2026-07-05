//! Async render orchestrator. Spawns every segment module concurrently via
//! `Io.async`, then awaits them in display order so the output is deterministic
//! even though the work overlaps. The prompt character is pure and is rendered
//! synchronously after the segment line.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const Io = std.Io;
const Span = @import("style.zig").Span;
const Writer = std.Io.Writer;
const character = @import("module_character.zig");
const cmd_duration = @import("module_cmd_duration.zig");
const directory = @import("module_directory.zig");
const git = @import("module_git.zig");
const language = @import("module_language.zig");
const style = @import("style.zig");

/// Segment modules in display order. Each has signature
/// `fn (Io, Allocator, *const Context) ?[]const Span` and is run concurrently; a
/// null (or empty) result means the module chose not to appear.
const modules = .{
    directory.run,
    git.run,
    language.run,
    cmd_duration.run,
};

/// Written between adjacent visible segments: a light grey dot, padded so it
/// breathes between the colored segments on either side.
const separator: Span = .{ .style = .{ .color = .bright_black }, .text = " · " };

/// Renders the full prompt to `w`. All modules are spawned before any is
/// awaited, so their I/O overlaps; awaiting in array order keeps layout stable.
pub fn render(io: Io, arena: Allocator, ctx: *const Context, w: *Writer) Writer.Error!void {
    var futures: [modules.len]Io.Future(?[]const Span) = undefined;
    inline for (modules, 0..) |module_fn, idx| {
        futures[idx] = io.async(module_fn, .{ io, arena, ctx });
    }

    var wrote_any = false;
    for (&futures) |*future| {
        const spans = future.await(io) orelse continue;
        if (spans.len == 0) continue;

        if (wrote_any) try style.write(w, ctx.shell, separator.style, separator.text);

        for (spans) |span| try style.write(w, ctx.shell, span.style, span.text);
        wrote_any = true;
    }

    // The character always appears, on its own line, with a trailing space so
    // the cursor sits one column clear of the symbol.
    try w.writeByte('\n');
    const ch = character.run(io, ctx);
    try style.write(w, ctx.shell, ch.style, ch.text);
    try w.writeByte(' ');
}
