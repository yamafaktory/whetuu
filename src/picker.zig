//! Interactive, type-to-filter history picker. Renders a full-screen list on
//! the controlling terminal (`/dev/tty`) in raw mode — deliberately independent
//! of stdio, so the chosen command is returned to the caller (and thence to
//! stdout) while the UI never touches the pipe the shell is capturing. The list
//! is bottom-anchored: the most recent command sits just above the search line,
//! older commands climb upward. Pure list-filtering is split out for testing;
//! the render/input loop is inherently terminal I/O and is exercised by hand.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const linux = std.os.linux;
const posix = std.posix;

const Entry = @import("history.zig").Entry;
const style = @import("style.zig");
const time_ago = @import("time_ago.zig");

/// Central SGR escapes; the picker writes to the terminal directly, so it
/// needs no shell wrapping.
const sgr = style.sgr;

/// whetuu's emblem, shown as the search prompt.
const star = style.icon.star;

/// Fixed width of the relative-time column, sized for the longest label
/// ("11mo"), so commands line up just past it.
const time_width = 4;

/// Terminal dimensions, with sane fallbacks when the size cannot be queried.
const Size = struct {
    cols: u16,
    rows: u16,
};

/// A keypress decoded from the raw terminal input stream.
const Key = union(enum) {
    char: u8,
    enter,
    tab,
    backspace,
    up,
    down,
    cancel,
    tick,
    other,
};

/// Opens the picker over `items` (newest first), returning the chosen command
/// or null when the user cancels, the list is empty, or no controlling terminal
/// is available. `initial` seeds the query — the shell passes whatever was
/// already typed on the command line, so opening the picker never loses it.
/// Tab copies the selected entry into the query (with a trailing
/// space) so flags can be appended; Enter returns the selected entry, or the
/// query text itself when nothing matches it. Entry ages are re-read from the
/// clock on every frame and the key read times out once a second, so the time
/// column stays live while the picker idles. Per-frame allocations (the
/// filtered list and the frame buffer) come from a scratch arena reset every
/// iteration, so an idle picker's memory stays bounded no matter how long it
/// ticks; only the query and the returned command live on `arena`. The
/// terminal is always restored on exit.
pub fn pick(io: Io, arena: Allocator, items: []const Entry, initial: []const u8) ?[]const u8 {
    if (items.len == 0) return null;

    const fd = posix.openat(posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return null;
    defer _ = linux.close(fd);

    const original = posix.tcgetattr(fd) catch return null;
    enterRaw(fd, original) catch return null;
    defer posix.tcsetattr(fd, .FLUSH, original) catch {};

    writeAll(fd, "\x1b[?1049h");
    defer writeAll(fd, "\x1b[?1049l");

    var frame_arena: std.heap.ArenaAllocator = .init(arena);
    var query: std.ArrayList(u8) = .empty;
    query.appendSlice(arena, initial) catch {};
    var selected: usize = 0;
    var base: usize = 0;

    while (true) {
        _ = frame_arena.reset(.retain_capacity);
        const scratch = frame_arena.allocator();
        const now = Io.Clock.now(.real, io).toSeconds();
        const shown = filter(scratch, items, query.items) catch items;
        if (selected >= shown.len) selected = if (shown.len == 0) 0 else shown.len - 1;

        render(scratch, fd, query.items, shown, selected, &base, size(fd), now);

        switch (readKey(fd)) {
            .up => {
                if (selected + 1 < shown.len) selected += 1;
            },
            .down => {
                if (selected > 0) selected -= 1;
            },
            .enter => return if (shown.len == 0) queryFallback(query.items) else shown[selected].command,
            .tab => {
                if (shown.len == 0) continue;

                query.clearRetainingCapacity();
                query.appendSlice(arena, shown[selected].command) catch {};
                query.append(arena, ' ') catch {};
                selected = 0;
            },
            .backspace => {
                _ = query.pop();
                selected = 0;
            },
            .char => |c| {
                query.append(arena, c) catch {};
                selected = 0;
            },
            .cancel => return null,
            .tick, .other => {},
        }
    }
}

/// Returns the subset of `items` matching `query`, order preserved. Each
/// whitespace-separated token in the query must appear (case-insensitive) in
/// the command, so `git pu` narrows to commands containing both.
fn filter(arena: Allocator, items: []const Entry, query: []const u8) ![]const Entry {
    if (std.mem.trim(u8, query, " ").len == 0) return items;

    var out: std.ArrayList(Entry) = .empty;
    for (items) |item| {
        if (matches(item.command, query)) try out.append(arena, item);
    }

    return out.toOwnedSlice(arena);
}

/// True when every token in `query` is a case-insensitive substring of `command`.
fn matches(command: []const u8, query: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, query, ' ');
    while (it.next()) |token| {
        if (!containsIgnoreCase(command, token)) return false;
    }

    return true;
}

/// The command Enter falls back to when no entry matches: the query text the
/// user typed (e.g. a tabbed entry plus new flags), stripped of the padding
/// spaces, or null when the query is effectively empty.
fn queryFallback(query: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, query, " ");
    return if (trimmed.len == 0) null else trimmed;
}

/// Case-insensitive substring test. An empty needle always matches.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }

    return false;
}

/// Switches the terminal to raw mode: no line buffering, no echo, and signals
/// delivered as bytes so we can handle Ctrl-C ourselves. VMIN=0 with VTIME=10
/// makes a key read give up after one second so the frame (and the entry ages
/// in it) refreshes even while the user is idle.
fn enterRaw(fd: posix.fd_t, original: posix.termios) !void {
    var raw = original;
    raw.lflag.ICANON = false;
    raw.lflag.ECHO = false;
    raw.lflag.ISIG = false;
    raw.lflag.IEXTEN = false;
    raw.cc[@intFromEnum(posix.V.MIN)] = 0;
    raw.cc[@intFromEnum(posix.V.TIME)] = 10;

    try posix.tcsetattr(fd, .FLUSH, raw);
}

/// Reads one keypress, decoding the escape sequences for the arrow keys. A
/// read that comes back empty is the VTIME timeout elapsing, reported as a
/// `.tick` so the caller redraws with fresh entry ages.
fn readKey(fd: posix.fd_t) Key {
    var buf: [8]u8 = undefined;
    const n = posix.read(fd, &buf) catch return .cancel;
    if (n == 0) return .tick;

    if (buf[0] == 0x1b) {
        if (n >= 3 and buf[1] == '[') {
            return switch (buf[2]) {
                'A' => .up,
                'B' => .down,
                else => .other,
            };
        }

        return .cancel;
    }

    return switch (buf[0]) {
        '\r', '\n' => .enter,
        '\t' => .tab,
        0x7f, 0x08 => .backspace,
        0x03, 0x04 => .cancel,
        else => if (buf[0] >= 0x20 and buf[0] < 0x7f) Key{ .char = buf[0] } else .other,
    };
}

/// Draws the whole frame in one write. `base` is the newest index currently
/// visible (the bottom list row), carried across frames so the viewport scrolls
/// while keeping the selection on screen.
fn render(arena: Allocator, fd: posix.fd_t, query: []const u8, shown: []const Entry, selected: usize, base: *usize, term: Size, now: i64) void {
    const list_rows: usize = if (term.rows > 1) term.rows - 1 else 1;
    if (selected < base.*) base.* = selected;
    if (selected >= base.* + list_rows) base.* = selected + 1 - list_rows;

    var f: std.ArrayList(u8) = .empty;
    frame(arena, &f, query, shown, selected, base.*, list_rows, term.cols, now) catch return;
    writeAll(fd, f.items);
}

/// Builds the frame bytes into `f`. Split from `render` so a formatting failure
/// simply skips the frame rather than corrupting the terminal.
fn frame(arena: Allocator, f: *std.ArrayList(u8), query: []const u8, shown: []const Entry, selected: usize, base: usize, list_rows: usize, cols: u16, now: i64) !void {
    try f.appendSlice(arena, "\x1b[H\x1b[2J");

    var row: usize = 0;
    while (row < list_rows) : (row += 1) {
        const idx = base + (list_rows - 1 - row);
        if (idx < shown.len) try appendEntry(arena, f, shown[idx], now, idx == selected, cols);
        try f.appendSlice(arena, "\r\n");
    }

    // Search line pinned to the last row; no trailing newline so it never
    // scrolls, leaving the cursor parked right after the query. The query is
    // sanitized because Tab can copy a stored command into it.
    try f.appendSlice(arena, sgr.fg_purple ++ star ++ sgr.reset ++ " ");
    try f.appendSlice(arena, try sanitize(arena, query));
}

/// Appends one list row: a fixed-width relative-time column then the command.
/// The selected row spans the full width in the star's purple. The time column
/// is muted on every row, selected or not, so only the command stands out.
fn appendEntry(arena: Allocator, f: *std.ArrayList(u8), entry: Entry, now: i64, selected: bool, cols: usize) !void {
    var buf: [24]u8 = undefined;
    const when = time_ago.relative(&buf, now, entry.timestamp);

    const room = if (cols > time_width + 1) cols - time_width - 1 else 0;
    const command = truncate(try sanitize(arena, entry.command), room);

    if (!selected) {
        try f.appendSlice(arena, sgr.dim);
        try appendRightAligned(arena, f, when, time_width);
        try f.appendSlice(arena, sgr.reset ++ " ");
        try f.appendSlice(arena, command);

        return;
    }

    try f.appendSlice(arena, sgr.bg_purple ++ sgr.fg_lavender);
    try appendRightAligned(arena, f, when, time_width);
    try f.appendSlice(arena, sgr.bright_white ++ " ");
    try f.appendSlice(arena, command);
    try appendSpaces(arena, f, cols - (time_width + 1 + width(command)));
    try f.appendSlice(arena, sgr.reset);
}

/// Returns `text` with every control byte replaced by `?` (allocating only
/// when needed), so a stored command cannot inject escape sequences into the
/// list it is rendered in.
fn sanitize(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    for (text) |c| {
        if (style.isControlByte(c)) break;
    } else return text;

    const out = try arena.dupe(u8, text);
    for (out) |*c| {
        if (style.isControlByte(c.*)) c.* = '?';
    }

    return out;
}

/// Pads with spaces to `w` columns then appends `s`, right-aligning it so the
/// unit letters of the time column line up (no-op padding when already wider).
fn appendRightAligned(arena: Allocator, f: *std.ArrayList(u8), s: []const u8, w: usize) !void {
    const shown_width = width(s);
    if (shown_width < w) try appendSpaces(arena, f, w - shown_width);
    try f.appendSlice(arena, s);
}

/// Appends `n` spaces.
fn appendSpaces(arena: Allocator, f: *std.ArrayList(u8), n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try f.append(arena, ' ');
}

/// Column count of `text`, counting each codepoint as one column so multibyte
/// glyphs are not overcounted by their byte length.
fn width(text: []const u8) usize {
    return std.unicode.utf8CountCodepoints(text) catch text.len;
}

/// Caps a line to `cols` columns, backing off to a UTF-8 boundary so a
/// multibyte glyph is never split mid-sequence.
fn truncate(line: []const u8, cols: usize) []const u8 {
    if (line.len <= cols) return line;

    var end: usize = cols;
    while (end > 0 and line[end] & 0xc0 == 0x80) end -= 1;
    return line[0..end];
}

/// Queries the terminal size, falling back to 24x80 when the ioctl is
/// unavailable (e.g. the tty is a pipe).
fn size(fd: posix.fd_t) Size {
    var ws: posix.winsize = undefined;
    const rc = std.os.linux.ioctl(fd, posix.T.IOCGWINSZ, @intFromPtr(&ws));
    if (@as(isize, @bitCast(rc)) < 0 or ws.row == 0) return .{ .cols = 80, .rows = 24 };
    return .{ .cols = if (ws.col == 0) 80 else ws.col, .rows = ws.row };
}

/// Writes all of `bytes` to `fd`, retrying short writes and dropping the rest on
/// error (a broken tty is not worth aborting the whole picker over).
fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var i: usize = 0;
    while (i < bytes.len) {
        const rc = linux.write(fd, bytes[i..].ptr, bytes.len - i);
        const written: isize = @bitCast(rc);
        if (written <= 0) return;
        i += @intCast(written);
    }
}

test "matches requires every query token" {
    try std.testing.expect(matches("git push origin", "git pu"));
    try std.testing.expect(matches("git push origin", "PUSH"));
    try std.testing.expect(!matches("git push origin", "git pull"));
    try std.testing.expect(matches("anything", ""));
}

test "appendRightAligned pads on the left so unit letters line up" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    try appendRightAligned(arena.allocator(), &f, "9m", time_width);
    try std.testing.expectEqualStrings("  9m", f.items);

    f.clearRetainingCapacity();
    try appendRightAligned(arena.allocator(), &f, "11mo", time_width);
    try std.testing.expectEqualStrings("11mo", f.items);
}

test "filter narrows to matching entries, order preserved" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const items = [_]Entry{
        .{ .command = "git push", .timestamp = 3 },
        .{ .command = "cargo test", .timestamp = 2 },
        .{ .command = "git pull", .timestamp = 1 },
    };
    const got = try filter(arena.allocator(), &items, "git");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("git push", got[0].command);
    try std.testing.expectEqualStrings("git pull", got[1].command);
}

test "selected row mutes the time column in lavender" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    try appendEntry(arena.allocator(), &f, .{ .command = "ls", .timestamp = 40 }, 100, true, 80);
    try std.testing.expect(std.mem.indexOf(u8, f.items, sgr.fg_lavender ++ "  1m" ++ sgr.bright_white ++ " ls") != null);
}

test "rows replace control bytes in stored commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    try appendEntry(arena.allocator(), &f, .{ .command = "ls\x1b[31mred", .timestamp = 40 }, 100, false, 80);
    try std.testing.expect(std.mem.indexOf(u8, f.items, "ls?[31mred") != null);
}

test "queryFallback returns the trimmed query and null when empty" {
    try std.testing.expectEqualStrings("git push --force", queryFallback("git push --force ").?);
    try std.testing.expect(queryFallback("   ") == null);
    try std.testing.expect(queryFallback("") == null);
}

test "truncate backs off to a utf-8 boundary" {
    // "·" is 2 bytes (0xc2 0xb7); a 1-column cap must not split it.
    try std.testing.expectEqualStrings("", truncate("\xc2\xb7", 1));
    try std.testing.expectEqualStrings("ab", truncate("abc", 2));
}
