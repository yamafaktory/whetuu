//! How many terminal columns text occupies.
//!
//! A terminal draws CJK, Hangul and emoji two columns wide, and combining marks
//! not at all, so counting codepoints puts every row after one of them in the
//! wrong column: the elision cuts in the wrong place and the selected row's bar
//! stops short. The ranges come from the Unicode Character Database, generated
//! into `width_table.zig` by `tools/gen-width.py`.
//!
//! Ambiguous width characters count as one column. They are the ones a terminal
//! draws differently depending on whether it thinks the locale is East Asian,
//! and one column is what a terminal not told otherwise picks.

const std = @import("std");
const unicode = std.unicode;

const table = @import("width_table.zig");

/// Asks for the emoji presentation of the character before it, which is drawn
/// two columns wide whatever that character measures on its own. This is what
/// separates a two column `❤️` from a one column `❤`.
const emoji_selector: u21 = 0xfe0f;

/// One step along a string: the bytes it consumed and the columns they take.
/// A character and the variation selector after it are one step, since their
/// width is a property of the pair rather than of either one.
pub const Step = struct { bytes: usize, cols: usize };

/// The step starting at the front of `text`. Assumes `text` is not empty.
///
/// A byte that begins no valid sequence is one byte of one column, which is
/// what a terminal draws for it. The picker sanitizes before measuring, so this
/// only guards the paths that do not.
pub fn step(text: []const u8) Step {
    const len = unicode.utf8ByteSequenceLength(text[0]) catch return .{ .bytes = 1, .cols = 1 };
    if (len > text.len) return .{ .bytes = 1, .cols = 1 };
    const cp = unicode.utf8Decode(text[0..len]) catch return .{ .bytes = 1, .cols = 1 };

    const rest = text[len..];
    if (rest.len > 0) {
        const next_len = unicode.utf8ByteSequenceLength(rest[0]) catch 0;
        if (next_len > 0 and next_len <= rest.len) {
            if (unicode.utf8Decode(rest[0..next_len]) catch null) |next_cp| {
                if (next_cp == emoji_selector) return .{ .bytes = len + next_len, .cols = 2 };
            }
        }
    }

    return .{ .bytes = len, .cols = codepoint(cp) };
}

/// The columns `text` occupies.
pub fn columns(text: []const u8) usize {
    var total: usize = 0;
    var rest = text;
    while (rest.len > 0) {
        const s = step(rest);
        total += s.cols;
        rest = rest[s.bytes..];
    }
    return total;
}

/// The columns one codepoint occupies on its own.
pub fn codepoint(cp: u21) usize {
    if (inRanges(&table.zero, cp)) return 0;
    if (inRanges(&table.wide, cp)) return 2;
    return 1;
}

/// Whether `cp` falls in one of `ranges`, which are sorted and disjoint.
fn inRanges(ranges: []const table.Range, cp: u21) bool {
    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const mid = low + (high - low) / 2;
        const range = ranges[mid];
        if (cp < range.first) {
            high = mid;
        } else if (cp > range.last) {
            low = mid + 1;
        } else {
            return true;
        }
    }
    return false;
}

test "ascii is one column each" {
    try std.testing.expectEqual(@as(usize, 0), columns(""));
    try std.testing.expectEqual(@as(usize, 10), columns("git commit"));
}

test "east asian characters take two columns" {
    try std.testing.expectEqual(@as(usize, 2), columns("\u{4f60}"));
    try std.testing.expectEqual(@as(usize, 4), columns("\u{4f60}\u{597d}"));
    // Hangul syllables are wide, and so is the fullwidth ASCII block.
    try std.testing.expectEqual(@as(usize, 2), columns("\u{d55c}"));
    try std.testing.expectEqual(@as(usize, 2), columns("\u{ff21}"));
    // A halfwidth katakana is not.
    try std.testing.expectEqual(@as(usize, 1), columns("\u{ff76}"));
}

test "emoji take two columns, with or without the selector" {
    // Emoji_Presentation, so wide on its own.
    try std.testing.expectEqual(@as(usize, 2), columns("\u{1f389}"));
    // Text presentation by default, and wide only once the selector asks.
    try std.testing.expectEqual(@as(usize, 1), columns("\u{2764}"));
    try std.testing.expectEqual(@as(usize, 2), columns("\u{2764}\u{fe0f}"));
    try std.testing.expectEqual(@as(usize, 2), columns("\u{26a0}\u{fe0f}"));
}

test "combining marks and invisible characters take no column" {
    // "e" then a combining acute: one column, two codepoints, three bytes.
    try std.testing.expectEqual(@as(usize, 1), columns("e\u{301}"));
    try std.testing.expectEqual(@as(usize, 0), columns("\u{200b}"));
    try std.testing.expectEqual(@as(usize, 0), columns("\u{fe0f}"));
    // A conjoining Hangul vowel composes onto the consonant before it.
    try std.testing.expectEqual(@as(usize, 2), columns("\u{1100}\u{1161}"));
}

test "a byte belonging to no codepoint counts as one column" {
    // The picker sanitizes before measuring, so this only guards the paths that
    // do not. It must terminate and never over-read.
    try std.testing.expectEqual(@as(usize, 1), columns("\xff"));
    try std.testing.expectEqual(@as(usize, 3), columns("a\xffb"));
    // Three letters and a lead byte whose continuation never arrived.
    try std.testing.expectEqual(@as(usize, 4), columns("caf\xc3"));
}

test "a step never splits a character and always advances" {
    const Context = struct {
        fn testOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
            var buf: [256]u8 = undefined;
            const text = buf[0..smith.slice(&buf)];

            var at: usize = 0;
            var total: usize = 0;
            while (at < text.len) {
                const s = step(text[at..]);
                try std.testing.expect(s.bytes > 0);
                try std.testing.expect(s.bytes <= text.len - at);
                try std.testing.expect(s.cols <= 2);
                at += s.bytes;
                total += s.cols;
            }
            try std.testing.expectEqual(text.len, at);
            try std.testing.expectEqual(total, columns(text));
        }
    };
    return std.testing.fuzz(Context{}, Context.testOne, .{});
}
