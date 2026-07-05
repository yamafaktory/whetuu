//! ANSI styling plus the per-shell wrapping of non-printing escape sequences.
//!
//! Every shell needs the color escapes marked as zero-width so its line editor
//! computes the prompt length correctly. Getting this wrong corrupts cursor
//! placement and line wrapping, so all wrapping lives here and nowhere else.

const std = @import("std");

const Allocator = std.mem.Allocator;
const Shell = @import("context.zig").Shell;
const Writer = std.Io.Writer;

/// A 4-bit ANSI foreground color. `default` emits no color code.
pub const Color = enum {
    blue,
    bright_black,
    cyan,
    default,
    green,
    magenta,
    red,
    white,
    yellow,

    /// SGR foreground code for this color. Caller handles `.default` separately.
    fn code(self: Color) u8 {
        return switch (self) {
            .blue => 34,
            .bright_black => 90,
            .cyan => 36,
            .default => 39,
            .green => 32,
            .magenta => 35,
            .red => 31,
            .white => 37,
            .yellow => 33,
        };
    }
};

/// A 24-bit truecolor, used for brand colors and the purple prompt character
/// that the 4-bit palette cannot express.
pub const Rgb = struct {
    b: u8,
    g: u8,
    r: u8,
};

/// Visual style for a segment's text. When `rgb` is set it wins over `color`,
/// emitting a truecolor escape; otherwise the 4-bit `color` (theme-aware) is
/// used. Failure-red deliberately uses `color = .red` so it matches the user's
/// terminal theme.
pub const Style = struct {
    bold: bool = false,
    color: Color = .default,
    rgb: ?Rgb = null,
};

/// A contiguous run of text with a single style. `text` is borrowed for the
/// lifetime of the render (usually arena-allocated). A module returns a slice of
/// spans (a "segment"); adjacent spans are written without a separator, while
/// separators go between whole segments.
pub const Span = struct {
    style: Style = .{},
    text: []const u8,
};

/// Allocates a one-element span slice — the common case for modules that emit a
/// single styled run.
pub fn single(arena: Allocator, sty: Style, text: []const u8) Allocator.Error![]const Span {
    const spans = try arena.alloc(Span, 1);
    spans[0] = .{ .style = sty, .text = text };
    return spans;
}

/// Writes the shell-specific opening marker for a non-printing sequence.
fn wrapStart(w: *Writer, shell: Shell) Writer.Error!void {
    switch (shell) {
        .bash => try w.writeAll("\\["),
        .zsh => try w.writeAll("%{"),
        .fish => {},
    }
}

/// Writes the shell-specific closing marker for a non-printing sequence.
fn wrapEnd(w: *Writer, shell: Shell) Writer.Error!void {
    switch (shell) {
        .bash => try w.writeAll("\\]"),
        .zsh => try w.writeAll("%}"),
        .fish => {},
    }
}

/// Writes `text` styled per `style`, with all escape sequences wrapped so the
/// target shell does not count them toward the prompt width. A `.default`,
/// non-bold style is written as plain text with no escapes at all.
pub fn write(w: *Writer, shell: Shell, style: Style, text: []const u8) Writer.Error!void {
    if (style.rgb == null and style.color == .default and !style.bold) {
        try w.writeAll(text);
        return;
    }

    try wrapStart(w, shell);
    try w.writeAll("\x1b[");
    if (style.bold) try w.writeAll("1;");

    if (style.rgb) |c| {
        try w.print("38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
    } else {
        try w.print("{d}m", .{style.color.code()});
    }

    try wrapEnd(w, shell);

    try w.writeAll(text);

    try wrapStart(w, shell);
    try w.writeAll("\x1b[0m");
    try wrapEnd(w, shell);
}

test "default style writes plain text with no escapes" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try write(&w, .fish, .{}, "hello");
    try std.testing.expectEqualStrings("hello", w.buffered());
}

test "bash wraps escapes in backslash brackets" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try write(&w, .bash, .{ .color = .red }, "x");
    try std.testing.expectEqualStrings("\\[\x1b[31m\\]x\\[\x1b[0m\\]", w.buffered());
}

test "zsh wraps escapes in percent braces and honors bold" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try write(&w, .zsh, .{ .color = .green, .bold = true }, "y");
    try std.testing.expectEqualStrings("%{\x1b[1;32m%}y%{\x1b[0m%}", w.buffered());
}

test "rgb emits a truecolor escape and overrides color" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try write(&w, .fish, .{ .bold = true, .rgb = .{ .r = 168, .g = 85, .b = 247 } }, "z");
    try std.testing.expectEqualStrings("\x1b[1;38;2;168;85;247mz\x1b[0m", w.buffered());
}
