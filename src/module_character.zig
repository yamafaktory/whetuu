//! Prompt character module: the glyph the user types after, on its own line.
//! Always a star; purple by default, tinted to the detected language's brand
//! color inside a recognized project. Either way it is forced to theme red
//! after a failed command so the error signal is never lost.

const std = @import("std");

const Color = @import("style.zig").Color;
const Context = @import("context.zig").Context;
const Io = std.Io;
const Lang = @import("module_language.zig").Lang;
const Rgb = @import("style.zig").Rgb;
const Span = @import("style.zig").Span;
const language = @import("module_language.zig");

/// Default glyph when no language is detected: nf-md-star_face (U+F09A5).
const star = "\u{f09a5}";

/// Default (success, no language) character color: purple.
const purple: Rgb = .{ .r = 168, .g = 85, .b = 247 };

/// Renders the character span, detecting the current project language to pick
/// the glyph and color.
pub fn run(io: Io, ctx: *const Context) Span {
    return choose(language.detect(io, ctx.cwd), ctx.exit_status);
}

/// Pure color decision, split out so it is testable without I/O: always the
/// star, in the language brand color (or purple), overridden to theme red on a
/// failed command.
fn choose(lang: ?Lang, exit_status: u8) Span {
    if (exit_status != 0) return .{ .style = .{ .bold = true, .color = .red }, .text = star };

    const color: Rgb = if (lang) |l| l.color else purple;
    return .{ .style = .{ .bold = true, .rgb = color }, .text = star };
}

test "default is the star in purple, red on failure" {
    const ok = choose(null, 0);
    try std.testing.expectEqualStrings(star, ok.text);
    try std.testing.expectEqual(purple, ok.style.rgb.?);

    const failed = choose(null, 1);
    try std.testing.expectEqualStrings(star, failed.text);
    try std.testing.expectEqual(Color.red, failed.style.color);
    try std.testing.expect(failed.style.rgb == null);
}

test "language dir keeps the star but uses the brand color" {
    const lang: Lang = .{ .argv = &.{}, .color = .{ .r = 1, .g = 2, .b = 3 }, .icon = "X", .markers = &.{}, .name = "x" };

    const ok = choose(lang, 0);
    try std.testing.expectEqualStrings(star, ok.text);
    try std.testing.expectEqual(lang.color, ok.style.rgb.?);

    const failed = choose(lang, 1);
    try std.testing.expectEqualStrings(star, failed.text);
    try std.testing.expectEqual(Color.red, failed.style.color);
}
