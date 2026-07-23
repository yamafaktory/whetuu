//! Interactive, type-to-filter history picker. Renders a full-screen list on
//! the controlling terminal (`/dev/tty`) in raw mode — deliberately independent
//! of stdio, so the chosen command is returned to the caller (and thence to
//! stdout) while the UI never touches the pipe the shell is capturing. The list
//! is bottom-anchored: the most recent command sits just above the search line,
//! older commands climb upward. It opens scoped to the current directory's
//! history (falling back to all history when the directory has none) and
//! Ctrl+G toggles the scope; a bar at the top of the screen names both scopes
//! with the active one highlighted (`~/dev/whetuu | all`). Rows are syntax
//! highlighted by `highlight.zig`, which is where the palette lives. Pure
//! list-filtering is split out for testing; the render/input loop is inherently
//! terminal I/O and is exercised by hand.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const posix = std.posix;

const Entry = @import("history.zig").Entry;
const collapseHome = @import("module_directory.zig").collapseHome;
const highlight = @import("highlight.zig");
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

/// Marks where a command too wide for the terminal lost its middle.
const ellipsis = "…";
const ellipsis_width = 1;

/// The cursor is parked on the search line, so it is hidden for the redraw that
/// walks past every row to get back there.
const hide_cursor = "\x1b[?25l";
const show_cursor = "\x1b[?25h";

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
    scope,
    cancel,
    tick,
    other,
};

/// Which slice of history the list shows: the current directory's or all of it.
const Scope = enum { dir, all };

/// The rendered scope bar plus its display width, which cannot be derived from
/// `text` because of the embedded SGR escapes.
const ScopeBar = struct {
    text: []const u8,
    cols: usize,
};

/// Caller-supplied context for one picker session.
pub const Options = struct {
    /// Seeds the query — the shell passes whatever was already typed on the
    /// command line, so opening the picker never loses it.
    initial: []const u8 = "",
    /// Absolute current directory, the target of the `.dir` scope. Empty
    /// disables scoping entirely (the picker stays on all history).
    cwd: []const u8 = "",
    /// `$HOME`, used only to shorten the scope label (`~/dev/whetuu`).
    home: []const u8 = "",
};

/// Opens the picker over `items` (newest first), returning the chosen command
/// or null when the user cancels, the list is empty, or no controlling terminal
/// is available. The list opens scoped to `opts.cwd` when that directory has
/// history (all history otherwise) and Ctrl+G toggles the scope. Tab copies
/// the selected entry into the query (with a trailing space) so flags can be
/// appended; Enter returns the selected entry, or the query text itself when
/// nothing matches it. Entry ages are re-read from the clock on every frame
/// and the key read times out once a second, so the time column stays live
/// while the picker idles.
///
/// Three arenas keep an idle picker from growing or from touching the terminal
/// for no reason. The frame buffer comes from a scratch arena reset every
/// iteration. Scope selection and query matching each get their own arena and
/// rerun only when their own input moves, so a tick filters nothing and a
/// keystroke never re-hashes the whole store to dedupe it again. The last frame
/// written is kept on `arena` and compared against the next one, so a redraw
/// that would change nothing is never sent. The terminal is always restored on
/// exit.
pub fn pick(io: Io, arena: Allocator, items: []const Entry, opts: Options) ?[]const u8 {
    if (items.len == 0) return null;

    const fd = posix.openat(posix.AT.FDCWD, "/dev/tty", .{ .ACCMODE = .RDWR }, 0) catch return null;
    const tty: Io.File = .{ .handle = fd, .flags = .{ .nonblocking = false } };
    defer tty.close(io);

    const original = posix.tcgetattr(fd) catch return null;
    enterRaw(fd, original) catch return null;
    defer posix.tcsetattr(fd, .FLUSH, original) catch {};

    writeAll(io, tty, "\x1b[?1049h");
    defer writeAll(io, tty, "\x1b[?1049l" ++ show_cursor);

    var frame_arena: std.heap.ArenaAllocator = .init(arena);
    var scope_arena: std.heap.ArenaAllocator = .init(arena);
    var list_arena: std.heap.ArenaAllocator = .init(arena);
    var drawn: std.ArrayList(u8) = .empty;
    var query: std.ArrayList(u8) = .empty;
    query.appendSlice(arena, opts.initial) catch {};
    var scope = initialScope(items, opts.cwd);
    var selected: usize = 0;
    var base: usize = 0;
    var input: Input = .{};
    var in_scope: []const Entry = &.{};
    var shown: []const Entry = &.{};
    var rescope = true;
    var refilter = true;

    while (true) {
        _ = frame_arena.reset(.retain_capacity);
        const scratch = frame_arena.allocator();
        const now = Io.Clock.now(.real, io).toSeconds();
        const term = size(io, tty);

        if (rescope) {
            _ = scope_arena.reset(.retain_capacity);
            in_scope = scoped(scope_arena.allocator(), items, scope, opts.cwd) catch items;
            rescope = false;
        }
        if (refilter) {
            _ = list_arena.reset(.retain_capacity);
            shown = matching(list_arena.allocator(), in_scope, query.items) catch in_scope;
            refilter = false;
        }
        if (selected >= shown.len) selected = if (shown.len == 0) 0 else shown.len - 1;

        const list_rows: usize = if (term.rows > 2) term.rows - 2 else 1;
        if (selected < base) base = selected;
        if (selected >= base + list_rows) base = selected + 1 - list_rows;

        render(io, scratch, arena, tty, &drawn, .{
            .query = query.items,
            .shown = shown,
            .selected = selected,
            .base = base,
            .list_rows = list_rows,
            .cols = term.cols,
            .now = now,
            .bar = scopeBar(scratch, scope, opts.cwd, opts.home, term.cols / 3) catch null,
        });

        switch (input.next(fd)) {
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
                refilter = true;
            },
            .backspace => {
                if (query.pop() != null) refilter = true;
                selected = 0;
            },
            .char => |c| {
                query.append(arena, c) catch {};
                selected = 0;
                refilter = true;
            },
            .scope => {
                if (opts.cwd.len == 0) continue;

                scope = if (scope == .dir) .all else .dir;
                selected = 0;
                rescope = true;
                refilter = true;
            },
            .cancel => return null,
            .tick, .other => {},
        }
    }
}

/// The scope the picker opens in: the current directory when it has history,
/// otherwise all — so the first up-arrow in a fresh directory never looks
/// broken.
fn initialScope(items: []const Entry, cwd: []const u8) Scope {
    if (cwd.len == 0) return .all;

    for (items) |item| {
        if (std.mem.eql(u8, item.cwd, cwd)) return .dir;
    }

    return .all;
}

/// Returns the entries `scope` admits, order preserved. The `.dir` scope keeps
/// only entries recorded in `cwd`; the `.all` scope collapses the same command
/// run in several directories to its newest occurrence.
///
/// No query is involved, which is the point: hashing every command to dedupe it
/// costs several times what matching a query does, and the result cannot change
/// between keystrokes. The picker runs this once per scope and narrows the
/// result with `matching`.
fn scoped(arena: Allocator, items: []const Entry, scope: Scope, cwd: []const u8) ![]const Entry {
    var seen: std.StringHashMap(void) = .init(arena);
    var out: std.ArrayList(Entry) = .empty;
    for (items) |item| {
        switch (scope) {
            .dir => if (!std.mem.eql(u8, item.cwd, cwd)) continue,
            .all => {
                if (seen.contains(item.command)) continue;
                try seen.put(item.command, {});
            },
        }

        try out.append(arena, item);
    }

    return out.toOwnedSlice(arena);
}

/// Returns the entries of `items` matching `query`, order preserved. Each
/// whitespace-separated token in the query must appear (case-insensitive) in
/// the command, so `git pu` narrows to commands containing both.
fn matching(arena: Allocator, items: []const Entry, query: []const u8) ![]const Entry {
    var out: std.ArrayList(Entry) = .empty;
    for (items) |item| {
        if (matches(item.command, query)) try out.append(arena, item);
    }

    return out.toOwnedSlice(arena);
}

/// Builds the bar shown at the top of the screen — both scopes with the
/// active one highlighted in the prompt's purple, the inactive one and the
/// separator dimmed: `~/dev/whetuu | all` (toggled with Ctrl+G). Null when
/// `cwd` is empty, since there is then nothing to toggle.
fn scopeBar(arena: Allocator, scope: Scope, cwd: []const u8, home: []const u8, max: usize) Allocator.Error!?ScopeBar {
    if (cwd.len == 0) return null;

    const active = sgr.bold ++ sgr.fg_purple;
    const dir_label = try dirLabel(arena, cwd, home, max);
    const dir_style: []const u8 = if (scope == .dir) active else sgr.dim;
    const all_style: []const u8 = if (scope == .all) active else sgr.dim;
    const text = try std.fmt.allocPrint(
        arena,
        "{s}{s}" ++ sgr.reset ++ sgr.dim ++ " | " ++ sgr.reset ++ "{s}all" ++ sgr.reset,
        .{ dir_style, dir_label, all_style },
    );

    return .{ .text = text, .cols = width(dir_label) + " | all".len };
}

/// The directory segment of the scope bar: `cwd` with home collapsed and long
/// paths kept to `max` columns by eliding the front.
fn dirLabel(arena: Allocator, cwd: []const u8, home: []const u8, max: usize) Allocator.Error![]const u8 {
    const collapsed = try collapseHome(arena, cwd, home);
    if (width(collapsed) <= max) return collapsed;
    return std.fmt.allocPrint(arena, "…{s}", .{tail(collapsed, max -| 1)});
}

/// The suffix of `text` that fits `cols` columns, cut on a UTF-8 boundary. The
/// mirror of `head`. Measures once and then skips the excess, rather than
/// re-measuring the remainder per column dropped — middle elision calls this on
/// exactly the longest rows, where that difference is quadratic.
fn tail(text: []const u8, cols: usize) []const u8 {
    const total = width(text);
    if (total <= cols) return text;

    var start: usize = 0;
    var skip = total - cols;
    while (skip > 0) : (skip -= 1) {
        start += 1;
        while (start < text.len and text[start] & 0xc0 == 0x80) start += 1;
    }

    return text[start..];
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

/// One decoded key and how many input bytes it consumed.
const Decoded = struct {
    key: Key,
    len: usize,
};

/// Decodes the first key in `bytes`. Assumes `bytes` is non-empty. Kept pure and
/// separate from the read so a pasted run decodes exactly like the same bytes
/// typed one at a time.
fn decodeKey(bytes: []const u8) Decoded {
    if (bytes[0] == 0x1b) {
        if (bytes.len >= 3 and bytes[1] == '[') {
            return .{
                .key = switch (bytes[2]) {
                    'A' => .up,
                    'B' => .down,
                    else => .other,
                },
                .len = 3,
            };
        }

        return .{ .key = .cancel, .len = 1 };
    }

    const key: Key = switch (bytes[0]) {
        '\r', '\n' => .enter,
        '\t' => .tab,
        0x07 => .scope, // Ctrl+G
        0x7f, 0x08 => .backspace,
        0x03, 0x04 => .cancel,
        else => if (bytes[0] >= 0x20 and bytes[0] < 0x7f) Key{ .char = bytes[0] } else .other,
    };
    return .{ .key = key, .len = 1 };
}

/// Buffers terminal input. A paste arrives as one burst rather than a byte per
/// read, so keys are handed out one at a time from the buffer and the next read
/// only happens once it is drained — otherwise every byte after the first in a
/// burst is silently dropped.
const Input = struct {
    buf: [1024]u8 = undefined,
    len: usize = 0,
    pos: usize = 0,

    /// Reads one keypress, decoding the escape sequences for the arrow keys. A
    /// read that comes back empty is the VTIME timeout elapsing, reported as a
    /// `.tick` so the caller redraws with fresh entry ages.
    fn next(in: *Input, fd: posix.fd_t) Key {
        if (in.buffered()) |key| return key;

        in.pos = 0;
        in.len = posix.read(fd, &in.buf) catch return .cancel;
        if (in.len == 0) return .tick;

        return in.buffered() orelse .tick;
    }

    /// The next key already sitting in the buffer, or null once it is drained.
    fn buffered(in: *Input) ?Key {
        if (in.pos == in.len) return null;
        const decoded = decodeKey(in.buf[in.pos..in.len]);
        in.pos += decoded.len;
        return decoded.key;
    }

    /// Fills the buffer as a read would, for tests.
    fn seed(in: *Input, bytes: []const u8) void {
        @memcpy(in.buf[0..bytes.len], bytes);
        in.len = bytes.len;
        in.pos = 0;
    }
};

test "a pasted burst yields every character, not just the first of each read" {
    var input: Input = .{};
    input.seed("--version");

    var typed: std.ArrayList(u8) = .empty;
    defer typed.deinit(std.testing.allocator);

    while (input.buffered()) |key| {
        switch (key) {
            .char => |c| try typed.append(std.testing.allocator, c),
            else => return error.UnexpectedKey,
        }
    }

    try std.testing.expectEqualStrings("--version", typed.items);
}

test "every character of a pasted run is decoded" {
    var typed: std.ArrayList(u8) = .empty;
    defer typed.deinit(std.testing.allocator);

    const pasted = "--version";
    var i: usize = 0;
    while (i < pasted.len) {
        const decoded = decodeKey(pasted[i..]);
        switch (decoded.key) {
            .char => |c| try typed.append(std.testing.allocator, c),
            else => return error.UnexpectedKey,
        }
        i += decoded.len;
    }

    try std.testing.expectEqualStrings(pasted, typed.items);
}

test "an arrow escape consumes the whole sequence" {
    const up = decodeKey("\x1b[A");
    try std.testing.expect(std.meta.activeTag(up.key) == .up);
    try std.testing.expectEqual(@as(usize, 3), up.len);

    const down = decodeKey("\x1b[B");
    try std.testing.expect(std.meta.activeTag(down.key) == .down);
    try std.testing.expectEqual(@as(usize, 3), down.len);

    const escape = decodeKey("\x1b");
    try std.testing.expect(std.meta.activeTag(escape.key) == .cancel);
    try std.testing.expectEqual(@as(usize, 1), escape.len);
}

test "a burst mixing text and control keys decodes in order" {
    const bytes = "ab\t\x1b[A\r";
    var keys: std.ArrayList(Key) = .empty;
    defer keys.deinit(std.testing.allocator);

    var i: usize = 0;
    while (i < bytes.len) {
        const decoded = decodeKey(bytes[i..]);
        try keys.append(std.testing.allocator, decoded.key);
        i += decoded.len;
    }

    try std.testing.expectEqual(@as(usize, 5), keys.items.len);
    try std.testing.expectEqual(@as(u8, 'a'), keys.items[0].char);
    try std.testing.expectEqual(@as(u8, 'b'), keys.items[1].char);
    try std.testing.expect(std.meta.activeTag(keys.items[2]) == .tab);
    try std.testing.expect(std.meta.activeTag(keys.items[3]) == .up);
    try std.testing.expect(std.meta.activeTag(keys.items[4]) == .enter);
}

/// Draws the whole frame in one write. `base` is the newest index currently
/// visible (the bottom list row), carried across frames so the viewport scrolls
/// while keeping the selection on screen.
/// `drawn` holds the bytes last written and lives on the long-lived `arena`,
/// which is what lets an unchanged frame be skipped. When remembering it fails
/// the buffer is cleared rather than left stale: an empty buffer matches no
/// frame, costing one redundant write instead of a missed redraw.
fn render(io: Io, scratch: Allocator, arena: Allocator, tty: Io.File, drawn: *std.ArrayList(u8), fr: Frame) void {
    var f: std.ArrayList(u8) = .empty;
    fr.build(scratch, &f) catch return;
    if (std.mem.eql(u8, drawn.items, f.items)) return;

    writeAll(io, tty, f.items);
    drawn.clearRetainingCapacity();
    drawn.appendSlice(arena, f.items) catch drawn.clearRetainingCapacity();
}

/// Everything one frame is drawn from. Grouped so `render` and `build` stay
/// readable, and so a frame can be compared against the last one as data.
const Frame = struct {
    query: []const u8,
    shown: []const Entry,
    selected: usize,
    base: usize,
    list_rows: usize,
    cols: u16,
    now: i64,
    bar: ?ScopeBar,

    /// Builds the frame bytes into `f`. Split from `render` so a formatting
    /// failure simply skips the frame rather than corrupting the terminal.
    ///
    /// Every line clears itself as it is drawn rather than the whole screen
    /// being erased up front. A full erase leaves the terminal free to present
    /// a blank screen before the repaint lands; erasing one line at a time
    /// bounds that to the line being rewritten. The cursor is hidden for the
    /// same reason, so it is not dragged down the list on every frame.
    ///
    /// The top line is cleared whole (`\x1b[2K`), since the scope bar jumps
    /// past the left of it without writing there. List rows clear from the
    /// cursor on (`\x1b[K`), which is safe because every row ends with a reset
    /// — erasing under an active background would smear the selected row's
    /// purple to the edge.
    fn build(fr: Frame, arena: Allocator, f: *std.ArrayList(u8)) !void {
        try f.appendSlice(arena, hide_cursor ++ "\x1b[H");

        // Scope bar pinned to the top row, right-aligned, skipped when it cannot
        // fit.
        try f.appendSlice(arena, "\x1b[2K");
        if (fr.bar) |b| {
            if (fr.cols > b.cols) {
                try f.appendSlice(arena, try std.fmt.allocPrint(arena, "\x1b[{d}G", .{fr.cols - b.cols + 1}));
                try f.appendSlice(arena, b.text);
            }
        }

        try f.appendSlice(arena, "\r\n");

        var row: usize = 0;
        while (row < fr.list_rows) : (row += 1) {
            const idx = fr.base + (fr.list_rows - 1 - row);
            if (idx < fr.shown.len) try appendEntry(arena, f, fr.shown[idx], fr.now, idx == fr.selected, fr.cols);
            try f.appendSlice(arena, "\x1b[K\r\n");
        }

        // Search line pinned to the last row; no trailing newline so it never
        // scrolls, leaving the cursor parked right after the query. The query is
        // sanitized because Tab can copy a stored command into it.
        try f.appendSlice(arena, sgr.fg_purple ++ star ++ sgr.reset ++ " ");
        try f.appendSlice(arena, try sanitize(arena, fr.query));
        try f.appendSlice(arena, "\x1b[J" ++ show_cursor);
    }
};

/// Appends one list row: a fixed-width relative-time column then the command,
/// syntax highlighted. The selected row spans the full width in the star's
/// purple and switches to the tints legible on it. The time column is muted on
/// every row, selected or not, so only the command stands out.
fn appendEntry(arena: Allocator, f: *std.ArrayList(u8), entry: Entry, now: i64, selected: bool, cols: usize) !void {
    var buf: [24]u8 = undefined;
    const when = time_ago.relative(&buf, now, entry.timestamp);

    const room = if (cols > time_width + 1) cols - time_width - 1 else 0;
    const tokens = try highlight.tokenize(arena, try oneLine(arena, entry.command));

    if (!selected) {
        try f.appendSlice(arena, sgr.dim);
        try appendRightAligned(arena, f, when, time_width);
        try f.appendSlice(arena, sgr.reset ++ " ");
        _ = try appendCommand(arena, f, tokens, room, selected);
        try f.appendSlice(arena, sgr.reset);

        return;
    }

    try f.appendSlice(arena, sgr.bg_purple ++ sgr.fg_lavender);
    try appendRightAligned(arena, f, when, time_width);
    try f.appendSlice(arena, " ");
    const shown = try appendCommand(arena, f, tokens, room, selected);
    try appendSpaces(arena, f, cols - (time_width + 1 + shown));
    try f.appendSlice(arena, sgr.reset);
}

/// Appends `tokens` colored by class, fitted to `cols` columns, and returns how
/// many were used. A command too long to fit loses its middle rather than its
/// end, so the program name and the tail that tells near-identical rows apart
/// both survive: several `cd <long path> && git …` entries are otherwise one
/// repeated prefix. The indicator belongs to no token, so it stays plain and
/// never takes a token's color. Each token emits only a foreground escape,
/// never a reset, so the selected row's background survives the whole command.
fn appendCommand(arena: Allocator, f: *std.ArrayList(u8), tokens: []const highlight.Token, cols: usize, selected: bool) !usize {
    const total = totalWidth(tokens);
    if (total <= cols) return appendRange(arena, f, tokens, 0, total, selected);

    // Too narrow to spend a column on the indicator, so fall back to a plain cut.
    if (cols <= ellipsis_width) return appendRange(arena, f, tokens, 0, cols, selected);

    const content = cols - ellipsis_width;
    const kept_tail = content / 2;
    _ = try appendRange(arena, f, tokens, 0, content - kept_tail, selected);
    try appendStyled(arena, f, ellipsis, .plain, selected);
    _ = try appendRange(arena, f, tokens, total - kept_tail, total, selected);

    return cols;
}

/// Appends the part of `tokens` covering columns `[from, to)`, and returns how
/// many columns that was. Tokens are consecutive slices of one command, so a
/// range is found by counting columns across them rather than by re-measuring.
fn appendRange(arena: Allocator, f: *std.ArrayList(u8), tokens: []const highlight.Token, from: usize, to: usize, selected: bool) !usize {
    var at: usize = 0;
    var used: usize = 0;
    for (tokens) |token| {
        const w = width(token.text);
        const start = @max(at, from);
        const end = @min(at + w, to);
        at += w;
        if (start >= end) continue;

        const text = if (start == at - w and end == at) token.text else head(tail(token.text, at - start), end - start);
        try appendStyled(arena, f, text, token.class, selected);
        used += width(text);
    }

    return used;
}

/// Appends `text` in the color `class` gets on this kind of row.
fn appendStyled(arena: Allocator, f: *std.ArrayList(u8), text: []const u8, class: highlight.Class, selected: bool) !void {
    var buf: [style.escape_len]u8 = undefined;
    const sty = if (selected) class.barStyle() else class.rowStyle();
    try f.appendSlice(arena, style.sgrEscape(&buf, sty));
    try f.appendSlice(arena, text);
}

/// Total display width of a tokenized command.
fn totalWidth(tokens: []const highlight.Token) usize {
    var total: usize = 0;
    for (tokens) |token| total += width(token.text);
    return total;
}

/// Returns `text` as the single line a list row shows: every whitespace run
/// collapsed to one space, the ends trimmed, and every remaining control byte
/// replaced by `?`. Collapsing has to come first, since a multi-line command
/// round-trips through the store with real newlines and would otherwise arrive
/// here as a row of `?`. This only changes how an entry is drawn — Enter and
/// Tab both hand back the stored command untouched, so what runs is what was
/// recorded, spacing and all.
fn oneLine(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (!needsCollapsing(text)) return sanitize(arena, text);

    var out: std.ArrayList(u8) = .empty;
    var pending = false;
    for (text) |c| {
        if (std.ascii.isWhitespace(c)) {
            pending = out.items.len > 0;
            continue;
        }
        if (pending) {
            try out.append(arena, ' ');
            pending = false;
        }

        try out.append(arena, if (style.isControlByte(c)) '?' else c);
    }

    return out.toOwnedSlice(arena);
}

/// True when `text` holds whitespace that a row would render differently:
/// anything but single interior spaces. Every non-space whitespace byte is a
/// control byte, so `sanitize` alone would turn it into `?`.
fn needsCollapsing(text: []const u8) bool {
    if (text.len == 0) return false;
    if (std.ascii.isWhitespace(text[0]) or std.ascii.isWhitespace(text[text.len - 1])) return true;

    var prev_space = false;
    for (text) |c| {
        if (c != ' ' and std.ascii.isWhitespace(c)) return true;
        if (c == ' ' and prev_space) return true;
        prev_space = c == ' ';
    }

    return false;
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

/// The prefix of `text` that fits `cols` columns, cut on a UTF-8 boundary so a
/// multibyte glyph is never split mid-sequence. The mirror of `tail`.
fn head(text: []const u8, cols: usize) []const u8 {
    var end: usize = 0;
    var seen: usize = 0;
    while (end < text.len and seen < cols) : (seen += 1) {
        end += 1;
        while (end < text.len and text[end] & 0xc0 == 0x80) end += 1;
    }

    return text[0..end];
}

/// Queries the terminal size, falling back to 24x80 when the ioctl is
/// unavailable (e.g. the tty is a pipe).
fn size(io: Io, tty: Io.File) Size {
    const fallback: Size = .{ .cols = 80, .rows = 24 };
    var ws: posix.winsize = .{ .row = 0, .col = 0, .xpixel = 0, .ypixel = 0 };
    const result = io.operate(.{ .device_io_control = .{
        .file = tty,
        .code = posix.T.IOCGWINSZ,
        .arg = &ws,
    } }) catch return fallback;
    if (result.device_io_control < 0 or ws.row == 0) return fallback;
    return .{ .cols = if (ws.col == 0) 80 else ws.col, .rows = ws.row };
}

/// Writes all of `bytes` to `fd`, dropping them on error (a broken tty is not
/// worth aborting the whole picker over). Short writes are retried by
/// `writeStreamingAll`.
fn writeAll(io: Io, tty: Io.File, bytes: []const u8) void {
    tty.writeStreamingAll(io, bytes) catch {};
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
    const a = arena.allocator();
    const got = try matching(a, try scoped(a, &items, .all, ""), "git");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("git push", got[0].command);
    try std.testing.expectEqualStrings("git pull", got[1].command);
}

test "dir scope keeps only the current directory's entries" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const items = [_]Entry{
        .{ .command = "zig build", .cwd = "/a", .timestamp = 3 },
        .{ .command = "zig build", .cwd = "/b", .timestamp = 2 },
        .{ .command = "ls", .cwd = "/a", .timestamp = 1 },
    };
    const a = arena.allocator();
    const got = try matching(a, try scoped(a, &items, .dir, "/a"), "");
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expectEqualStrings("zig build", got[0].command);
    try std.testing.expectEqualStrings("ls", got[1].command);
}

test "all scope collapses a command run in several directories to its newest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const items = [_]Entry{
        .{ .command = "zig build", .cwd = "/a", .timestamp = 3 },
        .{ .command = "zig build", .cwd = "/b", .timestamp = 2 },
    };
    const a = arena.allocator();
    const got = try matching(a, try scoped(a, &items, .all, ""), "");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("/a", got[0].cwd);
}

test "initialScope opens scoped only when the directory has history" {
    const items = [_]Entry{
        .{ .command = "zig build", .cwd = "/a", .timestamp = 1 },
    };
    try std.testing.expectEqual(Scope.dir, initialScope(&items, "/a"));
    try std.testing.expectEqual(Scope.all, initialScope(&items, "/fresh"));
    try std.testing.expectEqual(Scope.all, initialScope(&items, ""));
}

test "dirLabel collapses home and elides long paths from the front" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expectEqualStrings("~/dev/whetuu", try dirLabel(a, "/home/davy/dev/whetuu", "/home/davy", 20));
    try std.testing.expectEqualStrings("…/whetuu", try dirLabel(a, "/home/davy/dev/whetuu", "/home/davy", 8));
}

test "scopeBar highlights the active scope" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const active = sgr.bold ++ sgr.fg_purple;

    const dir_bar = (try scopeBar(a, .dir, "/home/davy/dev/whetuu", "/home/davy", 20)).?;
    try std.testing.expect(std.mem.indexOf(u8, dir_bar.text, active ++ "~/dev/whetuu") != null);
    try std.testing.expect(std.mem.indexOf(u8, dir_bar.text, sgr.dim ++ "all") != null);
    try std.testing.expectEqual(@as(usize, "~/dev/whetuu | all".len), dir_bar.cols);

    const all_bar = (try scopeBar(a, .all, "/home/davy/dev/whetuu", "/home/davy", 20)).?;
    try std.testing.expect(std.mem.indexOf(u8, all_bar.text, sgr.dim ++ "~/dev/whetuu") != null);
    try std.testing.expect(std.mem.indexOf(u8, all_bar.text, active ++ "all") != null);

    try std.testing.expect((try scopeBar(a, .dir, "", "/home/davy", 20)) == null);
}

test "frame pins the scope bar right-aligned on the top row" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    const fr: Frame = .{ .query = "ls", .shown = &.{}, .selected = 0, .base = 0, .list_rows = 1, .cols = 80, .now = 0, .bar = .{ .text = "BAR", .cols = 10 } };
    try fr.build(arena.allocator(), &f);
    try std.testing.expect(std.mem.startsWith(u8, f.items, hide_cursor ++ "\x1b[H\x1b[2K\x1b[71GBAR\r\n"));
}

test "frame drops the scope bar when the terminal is too narrow" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    const fr: Frame = .{ .query = "", .shown = &.{}, .selected = 0, .base = 0, .list_rows = 1, .cols = 8, .now = 0, .bar = .{ .text = "BAR", .cols = 10 } };
    try fr.build(arena.allocator(), &f);
    try std.testing.expect(std.mem.indexOf(u8, f.items, "BAR") == null);
}

test "a frame hides the cursor for the redraw and shows it again at the end" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    const fr: Frame = .{ .query = "ls", .shown = &.{}, .selected = 0, .base = 0, .list_rows = 3, .cols = 40, .now = 0, .bar = null };
    try fr.build(arena.allocator(), &f);
    try std.testing.expect(std.mem.startsWith(u8, f.items, hide_cursor));
    try std.testing.expect(std.mem.endsWith(u8, f.items, show_cursor));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, f.items, hide_cursor));
}

test "a frame clears each line instead of erasing the whole screen" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    const rows = 4;
    const fr: Frame = .{ .query = "", .shown = &.{}, .selected = 0, .base = 0, .list_rows = rows, .cols = 40, .now = 0, .bar = null };
    try fr.build(arena.allocator(), &f);
    try std.testing.expect(std.mem.indexOf(u8, f.items, "\x1b[2J") == null);
    try std.testing.expectEqual(@as(usize, rows), std.mem.count(u8, f.items, "\x1b[K\r\n"));
}

test "an unchanged frame is not written to the terminal again" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const entries = [_]Entry{.{ .command = "git status", .timestamp = 40 }};
    const fr: Frame = .{ .query = "", .shown = &entries, .selected = 0, .base = 0, .list_rows = 3, .cols = 40, .now = 100, .bar = null };

    var first: std.ArrayList(u8) = .empty;
    try fr.build(a, &first);
    var second: std.ArrayList(u8) = .empty;
    try fr.build(a, &second);
    try std.testing.expectEqualStrings(first.items, second.items);

    var later: std.ArrayList(u8) = .empty;
    var tick = fr;
    tick.now = 101;
    try tick.build(a, &later);
    try std.testing.expectEqualStrings(first.items, later.items);

    var moved: std.ArrayList(u8) = .empty;
    var other = fr;
    other.query = "g";
    try other.build(a, &moved);
    try std.testing.expect(!std.mem.eql(u8, first.items, moved.items));
}

test "selected row mutes the time column in lavender and tints the command" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    var buf: [style.escape_len]u8 = undefined;
    const expected = try std.mem.concat(a, u8, &.{
        sgr.fg_lavender ++ "  1m ",
        style.sgrEscape(&buf, highlight.Class.command.barStyle()),
        "ls",
    });

    var f: std.ArrayList(u8) = .empty;
    try appendEntry(a, &f, .{ .command = "ls", .timestamp = 40 }, 100, true, 80);
    try std.testing.expect(std.mem.indexOf(u8, f.items, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, f.items, sgr.reset) == f.items.len - sgr.reset.len);
}

test "rows color the command name apart from its arguments" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    var cmd_buf: [style.escape_len]u8 = undefined;
    var plain_buf: [style.escape_len]u8 = undefined;
    var flag_buf: [style.escape_len]u8 = undefined;
    const expected = try std.mem.concat(a, u8, &.{
        style.sgrEscape(&cmd_buf, highlight.Class.command.rowStyle()),
        "ls",
        style.sgrEscape(&plain_buf, highlight.Class.plain.rowStyle()),
        " ",
        style.sgrEscape(&flag_buf, highlight.Class.flag.rowStyle()),
        "-la",
        sgr.reset,
    });

    var f: std.ArrayList(u8) = .empty;
    try appendEntry(a, &f, .{ .command = "ls -la", .timestamp = 40 }, 100, false, 80);
    try std.testing.expect(std.mem.endsWith(u8, f.items, expected));
}

test "a row collapses whitespace runs and trims the ends" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expectEqualStrings("git status", try oneLine(a, "  git   status  "));
    try std.testing.expectEqualStrings("git status", try oneLine(a, "git\tstatus"));
    try std.testing.expectEqualStrings("a b c", try oneLine(a, "a \t\n b\n\nc"));
    try std.testing.expectEqualStrings("", try oneLine(a, "   "));
    try std.testing.expectEqualStrings("", try oneLine(a, ""));
}

test "a multi-line command reads as one line rather than a row of question marks" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const stored = "for f in *.zig\ndo\n\techo $f\ndone";
    try std.testing.expectEqualStrings("for f in *.zig do echo $f done", try oneLine(a, stored));
    try std.testing.expect(std.mem.indexOfScalar(u8, try oneLine(a, stored), '?') == null);
}

test "collapsing leaves an already single-spaced command untouched" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const command = "git commit -m 'one space between words'";
    const got = try oneLine(arena.allocator(), command);
    try std.testing.expectEqualStrings(command, got);
    try std.testing.expect(got.ptr == command.ptr);
}

test "collapsing still defangs escape sequences" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expectEqualStrings("ls ?[31mred", try oneLine(a, "ls  \x1b[31mred"));
    try std.testing.expectEqualStrings("ls?[31mred", try oneLine(a, "ls\x1b[31mred"));
}

test "rows replace control bytes in stored commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    try appendEntry(arena.allocator(), &f, .{ .command = "ls\x1b[31mred", .timestamp = 40 }, 100, false, 80);
    try std.testing.expect(std.mem.indexOf(u8, f.items, "ls?[31mred") != null);
}

test "a highlighted row still stops at the terminal width" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    const long = "echo 'aaaaaaaaaaaaaaaaaaaa' | grep --color bbbbbbbbbbbbbbbbbbbb";
    try appendEntry(arena.allocator(), &f, .{ .command = long, .timestamp = 40 }, 100, true, 20);
    try std.testing.expectEqual(@as(usize, 20), visibleWidth(f.items));
}

/// The visible text of a tokenized command fitted to `cols`, escapes stripped.
fn fitted(arena: Allocator, command: []const u8, cols: usize) ![]const u8 {
    var f: std.ArrayList(u8) = .empty;
    _ = try appendCommand(arena, &f, try highlight.tokenize(arena, command), cols, false);

    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < f.items.len) {
        if (f.items[i] == 0x1b) {
            while (i < f.items.len and f.items[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        try out.append(arena, f.items[i]);
        i += 1;
    }

    return out.toOwnedSlice(arena);
}

test "a command that fits is shown whole" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expectEqualStrings("git status", try fitted(a, "git status", 10));
    try std.testing.expectEqualStrings("git status", try fitted(a, "git status", 40));
}

test "a command too wide loses its middle, keeping the name and the tail" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const long = "cd /home/davy/cf/platform/.claude/worktrees/csd-2147 && git commit -S -C";
    try std.testing.expectEqualStrings("cd /home/davy/c…it commit -S -C", try fitted(a, long, 31));
    try std.testing.expectEqualStrings("hello…world", try fitted(a, "hello there world", 11));
}

test "near-identical rows stay distinguishable once elided" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const prefix = "cd /home/davy/cf/platform/.claude/worktrees/csd-2147 && ";
    const one = try fitted(a, prefix ++ "git commit -S -C REBASE_HEAD", 40);
    const two = try fitted(a, prefix ++ "GIT_EDITOR=true git rebase --continue", 40);
    try std.testing.expect(!std.mem.eql(u8, one, two));
    try std.testing.expect(std.mem.endsWith(u8, one, "REBASE_HEAD"));
    try std.testing.expect(std.mem.endsWith(u8, two, "--continue"));
}

test "an elided row uses exactly the width it was given" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const long = "cd ~/cf/tofu-plan-token && git commit -m 'fix: use TOFU_BOT_TOKEN' && git push";
    var cols: usize = 1;
    while (cols <= 90) : (cols += 1) {
        const shown = try fitted(a, long, cols);
        try std.testing.expectEqual(@min(cols, width(long)), width(shown));
    }
}

test "the ellipsis is drawn plain so it never takes a token color" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    var buf: [style.escape_len]u8 = undefined;
    const plain = style.sgrEscape(&buf, highlight.Class.plain.rowStyle());

    var f: std.ArrayList(u8) = .empty;
    _ = try appendCommand(a, &f, try highlight.tokenize(a, "nvim ~/.config/fish/config.fish"), 14, false);
    try std.testing.expect(std.mem.indexOf(u8, f.items, try std.mem.concat(a, u8, &.{ plain, ellipsis })) != null);
}

test "a width too narrow for the indicator falls back to a plain cut" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expectEqualStrings("", try fitted(a, "git status", 0));
    try std.testing.expectEqualStrings("g", try fitted(a, "git status", 1));
    try std.testing.expectEqualStrings("g…s", try fitted(a, "git status", 3));
}

/// Column count of `text` with every SGR escape skipped, for asserting that a
/// colored row occupies exactly the width it claims.
fn visibleWidth(text: []const u8) usize {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == 0x1b) {
            while (i < text.len and text[i] != 'm') i += 1;
            i += 1;
            continue;
        }
        if (text[i] & 0xc0 != 0x80) cols += 1;
        i += 1;
    }

    return cols;
}

test "queryFallback returns the trimmed query and null when empty" {
    try std.testing.expectEqualStrings("git push --force", queryFallback("git push --force ").?);
    try std.testing.expect(queryFallback("   ") == null);
    try std.testing.expect(queryFallback("") == null);
}

test "head and tail cut on a utf-8 boundary and measure in columns" {
    // "·" is 2 bytes (0xc2 0xb7) but one column, so a 1-column cap keeps it whole.
    try std.testing.expectEqualStrings("\xc2\xb7", head("\xc2\xb7", 1));
    try std.testing.expectEqualStrings("", head("\xc2\xb7", 0));
    try std.testing.expectEqualStrings("a\xc2\xb7", head("a\xc2\xb7c", 2));
    try std.testing.expectEqualStrings("ab", head("abc", 2));
    try std.testing.expectEqualStrings("abc", head("abc", 9));

    try std.testing.expectEqualStrings("\xc2\xb7c", tail("a\xc2\xb7c", 2));
    try std.testing.expectEqualStrings("bc", tail("abc", 2));
}
