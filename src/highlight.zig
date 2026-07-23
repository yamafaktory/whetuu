//! Shell-aware coloring for the history picker's command rows. Splits a stored
//! command into runs of one class each — the command name, flags, paths,
//! variable expansions, quoted strings and operators — so a row reads at a
//! glance instead of as a wall of one color.
//!
//! This is a highlighter, not a parser. It never runs anything and never
//! touches the filesystem, so a path is recognized by how it is written
//! (`/usr/bin`, `./x`, `~/dev`) rather than by whether it exists. A bare
//! `src` stays plain. The grammar it does track is the part that changes what
//! a run means: quotes hide whitespace and operators, `$` expands inside
//! double quotes but not single ones, an operator starts a new command while a
//! redirection does not, and an assignment prefix does not consume the command
//! position.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Rgb = @import("style.zig").Rgb;
const Style = @import("style.zig").Style;

/// What a run of command text is, as far as the highlighter can tell.
pub const Class = enum {
    command,
    flag,
    path,
    variable,
    string,
    operator,
    plain,

    /// The color a class gets on an ordinary row. These are the 4-bit ANSI
    /// colors, resolved by the user's terminal theme like the rest of whetuu's
    /// non-brand color, so the picker matches whatever palette they run.
    pub fn rowStyle(class: Class) Style {
        return switch (class) {
            .command => .{ .color = .green },
            .flag => .{ .color = .blue },
            .path => .{ .color = .magenta },
            .variable => .{ .color = .cyan },
            .string => .{ .color = .yellow },
            .operator => .{ .color = .red },
            .plain => .{},
        };
    }

    /// The color a class gets on the selected row, which is painted across the
    /// full width in the star's purple. The 4-bit palette has nothing legible
    /// against that background, so each hue is pinned to a pale tint of itself.
    pub fn barStyle(class: Class) Style {
        return .{ .rgb = switch (class) {
            .command => Rgb{ .r = 183, .g = 247, .b = 205 },
            .flag => Rgb{ .r = 184, .g = 224, .b = 255 },
            .path => Rgb{ .r = 255, .g = 201, .b = 242 },
            .variable => Rgb{ .r = 168, .g = 240, .b = 232 },
            .string => Rgb{ .r = 255, .g = 233, .b = 163 },
            .operator => Rgb{ .r = 255, .g = 192, .b = 192 },
            .plain => Rgb{ .r = 247, .g = 242, .b = 255 },
        } };
    }
};

/// A run of command text sharing one class. `text` borrows from the command it
/// was scanned from, so every token together is exactly the original bytes.
pub const Token = struct {
    class: Class,
    text: []const u8,
};

/// Splits `command` into consecutive tokens covering all of it, whitespace
/// included. Assumes `command` holds no control bytes — the picker sanitizes
/// before it highlights, so a stored escape sequence is already defanged.
pub fn tokenize(arena: Allocator, command: []const u8) Allocator.Error![]const Token {
    var scanner: Scanner = .{ .arena = arena, .src = command };
    while (scanner.pos < command.len) {
        const c = command[scanner.pos];
        if (isSpace(c)) {
            const start = scanner.pos;
            while (scanner.pos < command.len and isSpace(command[scanner.pos])) scanner.pos += 1;
            try scanner.emit(.plain, command[start..scanner.pos]);
            continue;
        }
        if (isOperator(c)) {
            try scanner.operator();
            continue;
        }

        try scanner.word();
    }

    return scanner.out.toOwnedSlice(arena);
}

/// One pass over a command. `expect_command` is the only carried state: it
/// marks the position where the next word names a program rather than an
/// argument.
const Scanner = struct {
    arena: Allocator,
    src: []const u8,
    pos: usize = 0,
    expect_command: bool = true,
    out: std.ArrayList(Token) = .empty,

    /// Appends a run, merging into the previous token when that token has the
    /// same class and ends exactly where this one starts. Merging keeps the
    /// list short and, more importantly, keeps the picker from re-emitting an
    /// identical color escape between two halves of one visual run.
    fn emit(scanner: *Scanner, class: Class, text: []const u8) Allocator.Error!void {
        if (text.len == 0) return;

        if (scanner.out.items.len > 0) {
            const last = &scanner.out.items[scanner.out.items.len - 1];
            if (last.class == class and last.text.ptr + last.text.len == text.ptr) {
                last.text.len += text.len;
                return;
            }
        }

        try scanner.out.append(scanner.arena, .{ .class = class, .text = text });
    }

    /// Consumes a run of operator characters. A control operator (`|`, `&&`,
    /// `;`) hands the command position to the next word; a redirection (`>`,
    /// `<`) does not, since what follows it is a file name.
    fn operator(scanner: *Scanner) Allocator.Error!void {
        const start = scanner.pos;
        while (scanner.pos < scanner.src.len and isOperator(scanner.src[scanner.pos])) scanner.pos += 1;

        const text = scanner.src[start..scanner.pos];
        try scanner.emit(.operator, text);
        scanner.expect_command = std.mem.indexOfNone(u8, text, "<>") != null;
    }

    /// Consumes one word and emits its runs. An assignment leaves the command
    /// position alone, so `RUST_LOG=debug cargo run` still names cargo.
    fn word(scanner: *Scanner) Allocator.Error!void {
        const end = wordEnd(scanner.src, scanner.pos);
        const raw = scanner.src[scanner.pos..end];
        scanner.pos = end;

        if (scanner.expect_command) {
            const name = assignmentLen(raw);
            if (name > 0) {
                try scanner.emit(.variable, raw[0..name]);
                try scanner.segment(raw[name..], .plain);
                return;
            }
        }

        const class = scanner.wordClass(raw);
        scanner.expect_command = false;
        try scanner.segment(raw, class);
    }

    /// The class of a whole word, which its unquoted runs inherit. The command
    /// position wins over everything, so `./gradlew` reads as the command it is
    /// rather than as the path it looks like.
    fn wordClass(scanner: *Scanner, raw: []const u8) Class {
        if (scanner.expect_command) return .command;
        if (raw.len > 0 and raw[0] == '-') return .flag;
        if (isPath(raw)) return .path;
        return .plain;
    }

    /// Emits `raw` as runs of `class`, carving out the quoted strings and
    /// variable expansions inside it.
    fn segment(scanner: *Scanner, raw: []const u8, class: Class) Allocator.Error!void {
        var i: usize = 0;
        var run: usize = 0;
        while (i < raw.len) {
            const c = raw[i];
            if (c == '\\' and i + 1 < raw.len) {
                i += 2;
                continue;
            }
            if (c != '\'' and c != '"' and c != '$') {
                i += 1;
                continue;
            }

            try scanner.emit(class, raw[run..i]);
            i = switch (c) {
                '\'' => try scanner.single(raw, i),
                '"' => try scanner.double(raw, i),
                else => try scanner.expansion(raw, i, class),
            };
            run = i;
        }

        try scanner.emit(class, raw[run..]);
    }

    /// Emits the single-quoted string opening at `i` and returns the index just
    /// past it. Nothing expands inside single quotes, so it is one run.
    fn single(scanner: *Scanner, raw: []const u8, i: usize) Allocator.Error!usize {
        const end = closingQuote(raw, i);
        try scanner.emit(.string, raw[i..end]);
        return end;
    }

    /// Emits the double-quoted string opening at `i`, with any `$` expansions
    /// inside it as their own runs, and returns the index just past it.
    fn double(scanner: *Scanner, raw: []const u8, i: usize) Allocator.Error!usize {
        const end = closingQuote(raw, i);
        var j = i + 1;
        var run = i;
        while (j + 1 < end) {
            if (raw[j] == '\\') {
                j += 2;
                continue;
            }
            if (raw[j] != '$') {
                j += 1;
                continue;
            }

            try scanner.emit(.string, raw[run..j]);
            j = try scanner.expansion(raw, j, .string);
            run = j;
        }

        try scanner.emit(.string, raw[run..end]);
        return end;
    }

    /// Emits the `$` expansion at `i` and returns the index just past it. A `$`
    /// that expands to nothing (a trailing one, or `$ `) belongs to `fallback`.
    fn expansion(scanner: *Scanner, raw: []const u8, i: usize, fallback: Class) Allocator.Error!usize {
        const end = expansionEnd(raw, i);
        if (end == i) {
            try scanner.emit(fallback, raw[i .. i + 1]);
            return i + 1;
        }

        try scanner.emit(.variable, raw[i..end]);
        return end;
    }
};

/// The index just past the word starting at `pos`. Whitespace and operators end
/// a word, except where a quoted span or a backslash escape swallows them, so
/// `grep 'a | b'` is two words rather than a pipeline.
fn wordEnd(src: []const u8, pos: usize) usize {
    var i = pos;
    while (i < src.len) {
        const c = src[i];
        if (c == '\\' and i + 1 < src.len) {
            i += 2;
            continue;
        }
        if (c == '\'' or c == '"') {
            i = closingQuote(src, i);
            continue;
        }
        if (isSpace(c) or isOperator(c)) break;
        i += 1;
    }

    return i;
}

/// The index just past the quote closing the one opened at `open`, or the end
/// of `src` when the command was stored half-typed and never closes it.
fn closingQuote(src: []const u8, open: usize) usize {
    const quote = src[open];
    var i = open + 1;
    while (i < src.len) : (i += 1) {
        if (quote == '"' and src[i] == '\\' and i + 1 < src.len) {
            i += 1;
            continue;
        }
        if (src[i] == quote) return i + 1;
    }

    return src.len;
}

/// The index just past the `$` expansion at `i`, or `i` when what follows the
/// `$` cannot start one. Covers `${BRACED}`, `$NAME` and the one-character
/// specials (`$?`, `$1`, `$$`).
fn expansionEnd(raw: []const u8, i: usize) usize {
    if (i + 1 >= raw.len) return i;

    const c = raw[i + 1];
    if (c == '{') {
        const close = std.mem.indexOfScalarPos(u8, raw, i + 2, '}') orelse return raw.len;
        return close + 1;
    }
    if (std.ascii.isAlphabetic(c) or c == '_') {
        var j = i + 1;
        while (j < raw.len and (std.ascii.isAlphanumeric(raw[j]) or raw[j] == '_')) j += 1;
        return j;
    }
    if (std.mem.indexOfScalar(u8, "?$!#*@-0123456789", c) != null) return i + 2;

    return i;
}

/// The length of the `NAME=` prefix when `raw` is an assignment, else 0.
fn assignmentLen(raw: []const u8) usize {
    if (raw.len == 0) return 0;
    if (!std.ascii.isAlphabetic(raw[0]) and raw[0] != '_') return 0;

    var i: usize = 1;
    while (i < raw.len and (std.ascii.isAlphanumeric(raw[i]) or raw[i] == '_')) i += 1;
    return if (i < raw.len and raw[i] == '=') i + 1 else 0;
}

/// True for a word written as a path. Only the leading form is trusted, since
/// the highlighter cannot look at the filesystem: `./x` and `~/dev` are paths,
/// a bare `src` is not, and neither is `feature/login` in `git switch`.
fn isPath(raw: []const u8) bool {
    if (std.mem.startsWith(u8, raw, "/")) return true;
    if (std.mem.startsWith(u8, raw, "./")) return true;
    if (std.mem.startsWith(u8, raw, "../")) return true;
    if (std.mem.startsWith(u8, raw, "~/")) return true;
    return std.mem.eql(u8, raw, "~");
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t';
}

/// The shell metacharacters that end a word. Redirection digits (`2>`) are left
/// to fall out as an ordinary word, which they colorwise already are.
fn isOperator(c: u8) bool {
    return std.mem.indexOfScalar(u8, "|&;<>()", c) != null;
}

/// Renders `command`'s classes as one letter each, aligned under it, so a test
/// reads as the thing it is checking. `.plain` is a space.
fn classMap(arena: Allocator, command: []const u8) ![]const u8 {
    const tokens = try tokenize(arena, command);
    var map: std.ArrayList(u8) = .empty;
    for (tokens) |token| {
        const letter: u8 = switch (token.class) {
            .command => 'c',
            .flag => 'f',
            .path => 'p',
            .variable => 'v',
            .string => 's',
            .operator => 'o',
            .plain => ' ',
        };
        try map.appendNTimes(arena, letter, token.text.len);
    }

    return map.toOwnedSlice(arena);
}

fn expectMap(command: []const u8, expected: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    try std.testing.expectEqualStrings(expected, try classMap(arena.allocator(), command));
}

test "tokens cover the command exactly, in order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const commands = [_][]const u8{
        "cargo clippy --all-targets -- -D warnings",
        "echo \"$HOME/dev\" | grep -i 'a b' > /tmp/out",
        "RUST_LOG=debug ./x --f=1 ~/y ${A}b $? $ ' \"",
        "",
        "   ",
    };
    for (commands) |command| {
        var rebuilt: std.ArrayList(u8) = .empty;
        for (try tokenize(arena.allocator(), command)) |token| {
            try rebuilt.appendSlice(arena.allocator(), token.text);
        }
        try std.testing.expectEqualStrings(command, rebuilt.items);
    }
}

test "the first word is the command and the rest are arguments" {
    try expectMap("cargo clippy", "ccccc       ");
    try expectMap("ls", "cc");
}

test "flags are colored wherever they appear" {
    try expectMap("cargo clippy --all-targets -- -D warnings", "ccccc        fffffffffffff ff ff         ");
}

test "an operator hands the command position to the next word, a redirection does not" {
    try expectMap("ls | wc -l", "cc o cc ff");
    try expectMap("a && b; c", "c oo co c");
    try expectMap("ls > out", "cc o    ");
    try expectMap("ls > /tmp/x", "cc o pppppp");
}

test "paths are recognized by how they are written, not by existing" {
    try expectMap("cd ~/dev", "cc ppppp");
    try expectMap("cat ./a ../b /c", "ccc ppp pppp pp");
    try expectMap("cd src", "cc    ");
    try expectMap("git switch feature/login", "ccc                     ");
}

test "the command position beats the path and flag rules" {
    try expectMap("./gradlew build", "ccccccccc      ");
    try expectMap("/usr/bin/env ls", "cccccccccccc   ");
}

test "single quotes hide operators and whitespace, and expand nothing" {
    try expectMap("grep 'a | b' x", "cccc sssssss  ");
    try expectMap("echo '$HOME'", "cccc sssssss");
}

test "double quotes expand variables inside the string" {
    try expectMap("echo \"$HOME/dev\"", "cccc svvvvvsssss");
    try expectMap("echo \"a\"", "cccc sss");
}

test "variable expansions are colored in every form" {
    try expectMap("echo $HOME ${A}b $? $1", "cccc vvvvv vvvv  vv vv");
}

test "a dollar that expands to nothing belongs to its surroundings" {
    try expectMap("echo $ x", "cccc    ");
    try expectMap("echo \"$\"", "cccc sss");
}

test "an assignment prefix does not consume the command position" {
    try expectMap("RUST_LOG=debug cargo run", "vvvvvvvvv      ccccc    ");
    try expectMap("A=1 B=2 ls", "vv  vv  cc");
}

test "an unterminated quote runs to the end rather than dropping text" {
    try expectMap("echo 'oops", "cccc sssss");
    try expectMap("echo \"$A", "cccc svv");
    try expectMap("echo ${A", "cccc vvv");
}

test "adjacent runs of one class merge into a single token" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const tokens = try tokenize(arena.allocator(), "a$ b");
    try std.testing.expectEqual(@as(usize, 2), tokens.len);
    try std.testing.expectEqualStrings("a$", tokens[0].text);
    try std.testing.expectEqualStrings(" b", tokens[1].text);
}

test "backslash escapes keep a metacharacter inside its word" {
    try expectMap("echo a\\ b", "cccc     ");
    try expectMap("echo a\\|b", "cccc     ");
}

test "row colors are distinct and bar tints stay bright enough to read on purple" {
    var seen_row: std.EnumSet(@import("style.zig").Color) = .{};
    for (std.enums.values(Class)) |class| {
        const row = class.rowStyle();
        try std.testing.expect(row.rgb == null);
        try std.testing.expect(!seen_row.contains(row.color));
        seen_row.insert(row.color);

        const bar = class.barStyle().rgb.?;
        try std.testing.expect(@as(u16, bar.r) + bar.g + bar.b > 500);
    }
}
