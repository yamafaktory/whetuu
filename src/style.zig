//! ANSI styling plus the per-shell wrapping of non-printing escape sequences.
//!
//! Every shell needs the color escapes marked as zero-width so its line editor
//! computes the prompt length correctly. Getting this wrong corrupts cursor
//! placement and line wrapping, so all wrapping lives here and nowhere else.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Writer = std.Io.Writer;

const Shell = @import("Env.zig").Shell;

/// A 4-bit ANSI foreground color. `default` emits no color code.
pub const Color = enum {
    default,
    red,
    green,
    yellow,
    blue,
    magenta,
    cyan,
    white,
    bright_black,

    /// SGR foreground code for this color. Caller handles `.default` separately.
    fn code(color: Color) u8 {
        return switch (color) {
            .default => 39,
            .red => 31,
            .green => 32,
            .yellow => 33,
            .blue => 34,
            .magenta => 35,
            .cyan => 36,
            .white => 37,
            .bright_black => 90,
        };
    }
};

/// A 24-bit truecolor, used for brand colors and the purple prompt character
/// that the 4-bit palette cannot express.
pub const Rgb = struct {
    r: u8,
    g: u8,
    b: u8,
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

/// Every Nerd Font glyph whetuu renders (except per-language logos, which
/// live in the language table). Codepoints in the doc comments — swap any
/// that render wrong in your font.
pub const icon = struct {
    /// Powerline branch (U+E0A0).
    pub const branch = "\u{e0a0}";
    /// nf-md-timer_sand (U+F051B), an hourglass.
    pub const duration = "\u{f051b}";
    /// nf-md-star_face (U+F09A5), whetuu's emblem.
    pub const star = "\u{f09a5}";
};

/// whetuu's brand purple, the color of the star emblem.
pub const purple: Rgb = .{ .r = 168, .g = 85, .b = 247 };

/// `purple` as the `R;G;B` fragment of an SGR truecolor escape, for building
/// escape sequences at comptime.
pub const purple_sgr = std.fmt.comptimePrint("{d};{d};{d}", .{ purple.r, purple.g, purple.b });

/// A light lavender tint of `purple`, used where muted text must stay
/// readable on the purple highlight.
pub const lavender: Rgb = .{ .r = 216, .g = 180, .b = 254 };

/// `lavender` as the `R;G;B` fragment of an SGR truecolor escape.
pub const lavender_sgr = std.fmt.comptimePrint("{d};{d};{d}", .{ lavender.r, lavender.g, lavender.b });

/// Raw SGR escapes for output written straight to a terminal (the picker, the
/// help screen), where no shell width-wrapping is needed. Prompt segments must
/// go through `write` instead.
pub const sgr = struct {
    pub const bg_purple = "\x1b[48;2;" ++ purple_sgr ++ "m";
    pub const bold = "\x1b[1m";
    pub const bright_white = "\x1b[97m";
    pub const dim = "\x1b[90m";
    pub const fg_lavender = "\x1b[38;2;" ++ lavender_sgr ++ "m";
    pub const fg_purple = "\x1b[38;2;" ++ purple_sgr ++ "m";
    pub const reset = "\x1b[0m";
};

/// Writes `text` styled per `style`, with all escape sequences wrapped so the
/// target shell does not count them toward the prompt width. A `.default`,
/// non-bold style is written as plain text with no escapes at all.
pub fn write(w: *Writer, shell: Shell, style: Style, text: []const u8) Writer.Error!void {
    if (style.rgb == null and style.color == .default and !style.bold) {
        try writeSanitized(w, text);
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

    try writeSanitized(w, text);

    try wrapStart(w, shell);
    try w.writeAll("\x1b[0m");
    try wrapEnd(w, shell);
}

/// Allocates a one-element span slice — the common case for modules that emit a
/// single styled run.
pub fn single(arena: Allocator, sty: Style, text: []const u8) Allocator.Error![]const Span {
    const spans = try arena.alloc(Span, 1);
    spans[0] = .{ .style = sty, .text = text };
    return spans;
}

/// True for bytes that must never reach the terminal raw (C0 controls and
/// DEL): they enable escape-sequence injection through untrusted text such as
/// directory or command names.
pub fn isControlByte(c: u8) bool {
    return c < 0x20 or c == 0x7f;
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

/// Writes `text` with every control byte replaced by `?`, so untrusted names
/// cannot smuggle escape sequences into the terminal.
fn writeSanitized(w: *Writer, text: []const u8) Writer.Error!void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (!isControlByte(c)) continue;
        try w.writeAll(text[start..i]);
        try w.writeByte('?');
        start = i + 1;
    }

    try w.writeAll(text[start..]);
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

test "control bytes in text are replaced, styled or not" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try write(&w, .fish, .{}, "a\x1b]2;x\x07b");
    try std.testing.expectEqualStrings("a?]2;x?b", w.buffered());

    var styled: Writer = .fixed(&buf);
    try write(&styled, .fish, .{ .color = .red }, "\x1bc");
    try std.testing.expectEqualStrings("\x1b[31m?c\x1b[0m", styled.buffered());
}

test "rgb emits a truecolor escape and overrides color" {
    var buf: [64]u8 = undefined;
    var w: Writer = .fixed(&buf);
    try write(&w, .fish, .{ .bold = true, .rgb = .{ .r = 168, .g = 85, .b = 247 } }, "z");
    try std.testing.expectEqualStrings("\x1b[1;38;2;168;85;247mz\x1b[0m", w.buffered());
}
