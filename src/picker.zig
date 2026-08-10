//! Interactive, type-to-filter history picker. Renders a full-screen list on
//! the controlling terminal (`/dev/tty`) in raw mode — deliberately independent
//! of stdio, so the chosen command is returned to the caller (and thence to
//! stdout) while the UI never touches the pipe the shell is capturing. The list
//! is bottom-anchored: the most recent command sits just above the search line,
//! older commands climb upward. Typing narrows the list by fuzzy match and
//! reorders it best-first, so the closest match takes that same bottom row —
//! see `search.zig` for what makes one match better than another. It opens
//! scoped to the current directory's
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
const search = @import("search.zig");
const style = @import("style.zig");
const time_ago = @import("time_ago.zig");

/// Central SGR escapes; the picker writes to the terminal directly, so it
/// needs no shell wrapping.
const sgr = style.sgr;

/// whetuu's emblem, shown beside the search field.
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

/// A keypress decoded from the raw terminal input stream. `newest` and `oldest`
/// are Home and End, named for what they do to a list that runs backwards in
/// time rather than for the keys that send them.
const Key = union(enum) {
    char: u8,
    enter,
    tab,
    backspace,
    up,
    down,
    newest,
    oldest,
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

/// What the shell does with a picked command: run it, or leave it on the
/// command line for the shell's own editor to work on.
pub const Action = enum { run, edit };

/// The exit status `whetuu history` uses to tell the shell integration that the
/// command it printed is for editing rather than running. The choice itself goes
/// to stdout either way, so the integrations only branch on this. Picked well
/// clear of the small statuses a shell or a signal produces on its own, so a
/// crashed picker can never read as an edit.
pub const edit_exit_code = 10;

/// A picked command and what to do with it.
pub const Choice = struct {
    command: []const u8,
    action: Action,
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
/// history (all history otherwise) and Ctrl+G toggles the scope. Enter picks the
/// selected entry to run, Tab picks it to edit, and both fall back to the query
/// when nothing matches it. See `accept`. Entry ages are re-read from the clock
/// on every frame and the key read times out once a second, so the time column
/// stays live while the picker idles.
///
/// Three arenas keep an idle picker from growing or from touching the terminal
/// for no reason. The frame buffer comes from a scratch arena reset every
/// iteration. Scope selection and query ranking each get their own arena and
/// rerun only when their own input moves, so a tick filters nothing and a
/// keystroke never re-hashes the whole store to dedupe it again nor lays it out
/// for the matcher again. The last frame
/// written is kept on `arena` and compared against the next one, so a redraw
/// that would change nothing is never sent. The terminal is always restored on
/// exit.
pub fn pick(io: Io, arena: Allocator, items: []const Entry, opts: Options) ?Choice {
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
    var corpus: ?search.Corpus = null;
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
            corpus = null;
            rescope = false;
        }
        if (refilter) {
            _ = list_arena.reset(.retain_capacity);
            shown = in_scope;
            if (isFilter(query.items)) {
                // Laying the scope out for the matcher costs about what reading
                // the store costs, and a list nobody has typed at is not
                // ranked, so it is built on the first keystroke rather than on
                // open. It then lasts until the scope changes.
                if (corpus == null) corpus = prepare(scope_arena.allocator(), in_scope) catch .empty;
                shown = ranked(list_arena.allocator(), in_scope, corpus.?, query.items, now) catch in_scope;
            }
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
            .up => if (selected + 1 < shown.len) {
                selected += 1;
            },
            .down => if (selected > 0) {
                selected -= 1;
            },
            .enter => return accept(query.items, shown, selected, .run),
            .tab => return accept(query.items, shown, selected, .edit),
            .newest => selected = 0,
            .oldest => selected = shown.len -| 1,
            .backspace => {
                if (popCodepoint(&query)) refilter = true;
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
        // The just-failed command carries the current directory but was never
        // stored, so counting it as history would open a fresh directory scoped
        // to that one row and hide everything else there is.
        if (item.failed) continue;
        if (std.mem.eql(u8, item.cwd, cwd)) return .dir;
    }

    return .all;
}

/// Drops the last codepoint of `query`, returning whether there was one. The
/// shell seeds the query with whatever was already on its command line, which
/// can hold a multibyte character, and dropping a byte of one would leave the
/// rest to render as replacement glyphs.
fn popCodepoint(query: *std.ArrayList(u8)) bool {
    if (query.items.len == 0) return false;

    var len: usize = 1;
    while (len < query.items.len and query.items[query.items.len - len] & 0xc0 == 0x80) len += 1;
    query.items.len -= len;
    return true;
}

/// Returns the entries `scope` admits, order preserved. The `.dir` scope keeps
/// only entries recorded in `cwd`; the `.all` scope collapses the same command
/// run in several directories to its newest occurrence, adding up how often
/// each directory ran it so the collapsed entry carries the whole total.
///
/// No query is involved, which is the point: hashing every command to dedupe it
/// costs several times what matching a query does, and the result cannot change
/// between keystrokes. The picker runs this once per scope and narrows the
/// result with `ranked`.
fn scoped(arena: Allocator, items: []const Entry, scope: Scope, cwd: []const u8) ![]const Entry {
    var seen: std.StringHashMap(u32) = .init(arena);
    var out: std.ArrayList(Entry) = .empty;
    for (items) |item| {
        switch (scope) {
            .dir => if (!std.mem.eql(u8, item.cwd, cwd)) continue,
            .all => {
                const gop = try seen.getOrPut(item.command);
                if (gop.found_existing) {
                    out.items[gop.value_ptr.*].count +|= item.count;
                    continue;
                }
                gop.value_ptr.* = @intCast(out.items.len);
            },
        }

        try out.append(arena, item);
    }

    return out.toOwnedSlice(arena);
}

/// Lays the scope's commands out for the fuzzy matcher. Run once per scope
/// rather than once per keystroke, because the layout is what makes a keystroke
/// cheap and nothing about it depends on what was typed. Held back until the
/// first keystroke, since a list nobody has typed at is never ranked.
fn prepare(arena: Allocator, items: []const Entry) !search.Corpus {
    const commands = try arena.alloc([]const u8, items.len);
    for (items, commands) |item, *command| command.* = item.command;
    return search.Corpus.prepare(arena, commands);
}

/// Whether the query narrows anything. Blank text is not a filter, so the list
/// stands as it came and nothing is laid out to match against.
fn isFilter(query: []const u8) bool {
    return std.mem.trim(u8, query, " \t").len > 0;
}

/// One scored entry, with everything the ordering needs so the comparison
/// itself stays a plain read of four fields.
const Ranked = struct {
    entry: Entry,
    score: u16,
    frecency: u32,
    /// Position in the unranked list, which is recency order. Breaks the last
    /// tie so the order is total and a redraw never reshuffles equal rows.
    at: usize,
};

/// Returns the entries of `items` that `query` matches, best match first.
///
/// Rank is the match score above all: a command the query fits well is shown
/// before one it merely fits, however long ago it ran. Frecency breaks ties
/// between equally good matches, and recency breaks what that leaves.
///
/// An empty query ranks nothing and returns `items` as they came, which is
/// newest first. That is what keeps the up arrow feeling like an up arrow —
/// opening the picker puts the last command run under the selection, and no
/// amount of running something often moves it.
fn ranked(arena: Allocator, items: []const Entry, corpus: search.Corpus, query: []const u8, now: i64) ![]const Entry {
    if (!isFilter(query) or corpus.len != items.len) return items;

    const scores = try arena.alloc(u16, items.len);
    try corpus.scoreAll(arena, query, scores);

    var hits: std.ArrayList(Ranked) = .empty;
    for (items, scores, 0..) |item, score, at| {
        if (score == 0) continue;
        try hits.append(arena, .{
            .entry = item,
            .score = score,
            .frecency = search.frecency(item.count, now - item.timestamp),
            .at = at,
        });
    }

    std.mem.sortUnstable(Ranked, hits.items, {}, better);

    const out = try arena.alloc(Entry, hits.items.len);
    for (hits.items, out) |hit, *slot| slot.* = hit.entry;
    return out;
}

/// Whether `a` belongs above `b`, which in a bottom-anchored list means nearer
/// the cursor.
fn better(_: void, a: Ranked, b: Ranked) bool {
    if (a.score != b.score) return a.score > b.score;
    if (a.frecency != b.frecency) return a.frecency > b.frecency;
    if (a.entry.timestamp != b.entry.timestamp) return a.entry.timestamp > b.entry.timestamp;
    return a.at < b.at;
}

/// Builds the bar shown at the top of the screen — both scopes with the
/// active one highlighted in the status line's purple, the inactive one and the
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

/// The command a pick falls back to when no entry matches: the query text the
/// user typed, stripped of the padding spaces, or null when the query is
/// effectively empty.
fn queryFallback(query: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, query, " ");
    return if (trimmed.len == 0) null else trimmed;
}

/// What a picking key hands back: the selected entry, or the typed query when
/// nothing matched it, paired with `action`. Null closes the picker with
/// nothing, which is what a key with neither a match nor a query means.
///
/// Enter and Tab differ only in `action`, so a command typed rather than
/// recalled can be edited on the shell's line too.
fn accept(query: []const u8, shown: []const Entry, selected: usize, action: Action) ?Choice {
    const command = if (shown.len == 0) queryFallback(query) orelse return null else shown[selected].command;
    return .{ .command = command, .action = action };
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
    if (bytes[0] == 0x1b) return decodeEscape(bytes);

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

/// Decodes the escape sequence starting at `bytes[0]`, which is the escape byte.
/// The whole sequence is consumed whatever it turns out to be, so a key the
/// picker has no use for is swallowed rather than leaving its tail to be read as
/// text: Delete arrives as `\x1b[3~`, and stopping after three bytes typed a
/// literal `~` into the query.
///
/// An escape that resolves into no sequence at all is the cancel key.
fn decodeEscape(bytes: []const u8) Decoded {
    // SS3, which is what a terminal in application cursor mode sends for the
    // arrows and for Home and End. The shell integrations bind both forms for
    // the same reason.
    if (bytes.len >= 3 and bytes[1] == 'O') return .{ .key = finalKey(bytes[2], ""), .len = 3 };
    if (bytes.len < 3 or bytes[1] != '[') return .{ .key = .cancel, .len = 1 };

    // CSI: parameter bytes, then intermediates, then the one final byte that
    // says which key it was.
    var i: usize = 2;
    while (i < bytes.len and bytes[i] >= 0x30 and bytes[i] <= 0x3f) i += 1;
    const params = bytes[2..i];
    while (i < bytes.len and bytes[i] >= 0x20 and bytes[i] <= 0x2f) i += 1;

    // Cut short by the end of the buffer. Swallow what arrived rather than let
    // the rest of a sequence read as text.
    if (i == bytes.len) return .{ .key = .other, .len = bytes.len };

    return .{ .key = finalKey(bytes[i], params), .len = i + 1 };
}

/// The key a sequence's final byte names, given its parameters. A modifier only
/// ever arrives as a parameter, so Ctrl+Up moves the selection exactly as a bare
/// Up does instead of typing the difference.
fn finalKey(final: u8, params: []const u8) Key {
    return switch (final) {
        'A' => .up,
        'B' => .down,
        'H' => .newest,
        'F' => .oldest,
        '~' => tildeKey(params),
        else => .other,
    };
}

/// The key a `CSI <n> ~` sequence names, the form most terminals use for the
/// editing keys. Delete is backspace here, since the cursor is parked at the end
/// of the query and there is never anything ahead of it to delete. Anything else
/// — a function key, a bracketed-paste marker — is swallowed.
fn tildeKey(params: []const u8) Key {
    const digits = params[0 .. std.mem.indexOfScalar(u8, params, ';') orelse params.len];
    const n = std.fmt.parseInt(u8, digits, 10) catch return .other;
    return switch (n) {
        1, 7 => .newest,
        3 => .backspace,
        4, 8 => .oldest,
        else => .other,
    };
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

/// The keys `bytes` decodes to, as the tag names, so a test reads as the
/// sequence it is checking.
fn decodeAll(arena: Allocator, bytes: []const u8) ![]const []const u8 {
    var tags: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const decoded = decodeKey(bytes[i..]);
        try tags.append(arena, switch (decoded.key) {
            .char => |c| try std.fmt.allocPrint(arena, "'{c}'", .{c}),
            else => @tagName(decoded.key),
        });
        i += decoded.len;
    }

    return tags.toOwnedSlice(arena);
}

fn expectKeys(bytes: []const u8, expected: []const []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const got = try decodeAll(arena.allocator(), bytes);
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, tag| try std.testing.expectEqualStrings(want, tag);
}

test "an unhandled escape sequence is swallowed whole, never typed into the query" {
    // Every one of these used to leave its tail behind as text: Delete typed a
    // `~`, Ctrl+Up typed `;5A`, and a bracketed paste typed its own markers.
    try expectKeys("\x1b[5~", &.{"other"}); // PageUp
    try expectKeys("\x1b[15~", &.{"other"}); // F5
    try expectKeys("\x1b[200~ls\x1b[201~", &.{ "other", "'l'", "'s'", "other" });
    try expectKeys("\x1b[<0;1;1M", &.{"other"}); // a mouse report

    // A sequence cut in half by the end of a read goes the same way, rather
    // than the half that arrived reading as text.
    try expectKeys("\x1b[1;5", &.{"other"});
}

test "a modifier does not change which key a sequence names" {
    try expectKeys("\x1b[1;5A", &.{"up"}); // Ctrl+Up
    try expectKeys("\x1b[1;2B", &.{"down"}); // Shift+Down
    try expectKeys("\x1b[3;5~", &.{"backspace"}); // Ctrl+Delete
}

test "the arrows work in application cursor mode, where they arrive as SS3" {
    // The shell integrations bind both forms because a terminal sends one or
    // the other depending on keypad mode. The picker read the SS3 form as a
    // bare escape, so the up arrow that opened it then closed it.
    try expectKeys("\x1bOA", &.{"up"});
    try expectKeys("\x1bOB", &.{"down"});
    try expectKeys("\x1bOH", &.{"newest"});
    try expectKeys("\x1bOF", &.{"oldest"});
}

test "Home and End jump to the ends of the list, Delete backspaces" {
    // The three forms terminals use for each.
    try expectKeys("\x1b[H", &.{"newest"});
    try expectKeys("\x1b[1~", &.{"newest"});
    try expectKeys("\x1b[7~", &.{"newest"});
    try expectKeys("\x1b[F", &.{"oldest"});
    try expectKeys("\x1b[4~", &.{"oldest"});
    try expectKeys("\x1b[8~", &.{"oldest"});

    // Nothing is ever ahead of the cursor, which is parked at the end of the
    // query, so Delete removes the character behind it.
    try expectKeys("\x1b[3~", &.{"backspace"});
}

test "backspace drops a whole character, not one byte of one" {
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(std.testing.allocator);

    // The shell seeds the query with its command line, so it can hold multibyte
    // text.
    try query.appendSlice(std.testing.allocator, "echo café");
    try std.testing.expect(popCodepoint(&query));
    try std.testing.expectEqualStrings("echo caf", query.items);

    try std.testing.expect(popCodepoint(&query));
    try std.testing.expectEqualStrings("echo ca", query.items);

    query.clearRetainingCapacity();
    try std.testing.expect(!popCodepoint(&query));
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
            const painted = if (idx < fr.shown.len)
                try appendEntry(arena, f, fr.shown[idx], fr.now, idx == fr.selected, fr.cols)
            else
                0;

            // A row that already covers the width has nothing left to clear,
            // and writing the last column leaves the cursor on it rather than
            // past it, so erasing from there would blank the cell just drawn.
            // That is the selected row losing its final column of purple.
            if (painted < fr.cols) try f.appendSlice(arena, "\x1b[K");
            try f.appendSlice(arena, "\r\n");
        }

        // Search line pinned to the last row; no trailing newline so it never
        // scrolls, leaving the cursor parked right after the query. The query is
        // sanitized because the shell seeds it with its own command line.
        try f.appendSlice(arena, sgr.fg_purple ++ star ++ sgr.reset ++ " ");
        try f.appendSlice(arena, try style.sanitize(arena, fr.query));
        try f.appendSlice(arena, "\x1b[J" ++ show_cursor);
    }
};

/// Appends one list row: a fixed-width relative-time column then the command,
/// syntax highlighted. The selected row spans the full width in the star's
/// purple and switches to the tints legible on it. The time column is muted on
/// every row, selected or not, so only the command stands out. The ephemeral
/// just-failed entry carries a red star between the time column and the
/// command, the same emblem the status line reddens after a failure.
fn appendEntry(arena: Allocator, f: *std.ArrayList(u8), entry: Entry, now: i64, selected: bool, cols: usize) !usize {
    var buf: [24]u8 = undefined;
    const when = time_ago.relative(&buf, now, entry.timestamp);

    const room = if (cols > time_width + 1) cols - time_width - 1 else 0;
    const tokens = try highlight.tokenize(arena, try oneLine(arena, entry.command));

    if (!selected) {
        const override: ?style.Style = if (entry.failed) .{ .color = .red } else null;
        try f.appendSlice(arena, sgr.dim);
        try appendRightAligned(arena, f, when, time_width);
        try f.appendSlice(arena, sgr.reset ++ " ");
        const shown = try appendCommand(arena, f, tokens, room, selected, override);
        try f.appendSlice(arena, sgr.reset);

        return @min(time_width + 1 + shown, cols);
    }

    // The failed entry gets a red bar with white text instead of the purple one.
    const bg: []const u8 = if (entry.failed) sgr.bg_red else sgr.bg_purple;
    const fg: []const u8 = if (entry.failed) sgr.fg_white else sgr.fg_lavender;
    const override: ?style.Style = if (entry.failed) .{ .color = .white } else null;
    try f.appendSlice(arena, bg);
    try f.appendSlice(arena, fg);
    try appendRightAligned(arena, f, when, time_width);
    try f.appendSlice(arena, " ");
    const shown = try appendCommand(arena, f, tokens, room, selected, override);
    try appendSpaces(arena, f, cols -| (time_width + 1 + shown));
    try f.appendSlice(arena, sgr.reset);

    // Padded to the full width, which is what makes the bar span the row.
    return @max(time_width + 1 + shown, cols);
}

/// Appends `tokens` colored by class, fitted to `cols` columns, and returns how
/// many were used. A command too long to fit loses its middle rather than its
/// end, so the program name and the tail that tells near-identical rows apart
/// both survive: several `cd <long path> && git …` entries are otherwise one
/// repeated prefix. The indicator belongs to no token, so it stays plain and
/// never takes a token's color. Each token emits only a foreground escape,
/// never a reset, so the selected row's background survives the whole command.
///
/// A non-null `override` paints every token that one color instead of its
/// syntax class, which is how the failed entry reads as one flat red run.
fn appendCommand(arena: Allocator, f: *std.ArrayList(u8), tokens: []const highlight.Token, cols: usize, selected: bool, override: ?style.Style) !usize {
    const total = totalWidth(tokens);
    if (total <= cols) return appendRange(arena, f, tokens, 0, total, selected, override);

    // Too narrow to spend a column on the indicator, so fall back to a plain cut.
    if (cols <= ellipsis_width) return appendRange(arena, f, tokens, 0, cols, selected, override);

    const content = cols - ellipsis_width;
    const kept_tail = content / 2;
    _ = try appendRange(arena, f, tokens, 0, content - kept_tail, selected, override);
    try appendStyled(arena, f, ellipsis, .plain, selected, override);
    _ = try appendRange(arena, f, tokens, total - kept_tail, total, selected, override);

    return cols;
}

/// Appends the part of `tokens` covering columns `[from, to)`, and returns how
/// many columns that was. Tokens are consecutive slices of one command, so a
/// range is found by counting columns across them rather than by re-measuring.
fn appendRange(arena: Allocator, f: *std.ArrayList(u8), tokens: []const highlight.Token, from: usize, to: usize, selected: bool, override: ?style.Style) !usize {
    var at: usize = 0;
    var used: usize = 0;
    for (tokens) |token| {
        const w = width(token.text);
        const start = @max(at, from);
        const end = @min(at + w, to);
        at += w;
        if (start >= end) continue;

        const text = if (start == at - w and end == at) token.text else head(tail(token.text, at - start), end - start);
        try appendStyled(arena, f, text, token.class, selected, override);
        used += width(text);
    }

    return used;
}

/// Appends `text` in `override` when set, otherwise the color `class` gets on
/// this kind of row.
fn appendStyled(arena: Allocator, f: *std.ArrayList(u8), text: []const u8, class: highlight.Class, selected: bool, override: ?style.Style) !void {
    var buf: [style.escape_len]u8 = undefined;
    const sty = override orelse (if (selected) class.barStyle() else class.rowStyle());
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
/// collapsed to one space, the ends trimmed, and everything left that cannot be
/// drawn replaced by `?`. Collapsing has to come first, since a multi-line
/// command round-trips through the store with real newlines and would otherwise
/// arrive here as a row of `?`. Defanging comes second and through `sanitize`,
/// so a row is held to the same rule as the rest of what whetuu draws. This only
/// changes how an entry is drawn — Enter and Tab both hand back the stored
/// command untouched, so what reaches the shell is what was recorded, spacing
/// and all.
fn oneLine(arena: Allocator, text: []const u8) Allocator.Error![]const u8 {
    if (!needsCollapsing(text)) return style.sanitize(arena, text);

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

        try out.append(arena, c);
    }

    return style.sanitize(arena, out.items);
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

/// The list the picker would show for `query`: scoped, then ranked, exactly as
/// `pick` builds it.
fn shownFor(arena: Allocator, items: []const Entry, scope: Scope, cwd: []const u8, query: []const u8, now: i64) ![]const Entry {
    const in_scope = try scoped(arena, items, scope, cwd);
    return ranked(arena, in_scope, try prepare(arena, in_scope), query, now);
}

/// The commands of a shown list, so a test reads as the rows it expects.
fn expectShown(got: []const Entry, expected: []const []const u8) !void {
    try std.testing.expectEqual(expected.len, got.len);
    for (expected, got) |want, entry| try std.testing.expectEqualStrings(want, entry.command);
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

test "a query narrows the list to what it matches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const items = [_]Entry{
        .{ .command = "git push", .timestamp = 3 },
        .{ .command = "cargo test", .timestamp = 2 },
        .{ .command = "git pull", .timestamp = 1 },
    };
    const a = arena.allocator();
    try expectShown(try shownFor(a, &items, .all, "", "git", 10), &.{ "git push", "git pull" });
}

test "a query matches loosely, not only as a substring" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const items = [_]Entry{
        .{ .command = "git commit --amend", .timestamp = 2 },
        .{ .command = "cargo test", .timestamp = 1 },
    };
    const a = arena.allocator();
    try expectShown(try shownFor(a, &items, .all, "", "gca", 10), &.{"git commit --amend"});
}

test "the best match comes first, however long ago it ran" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // The newest entry matches the query only by scattering it through the
    // middle of a word. The oldest starts two words with it. Recency used to
    // decide this outright, and typing the exact command left it at the top of
    // a list of things that merely contained the same letters.
    const items = [_]Entry{
        .{ .command = "echo 'go past unit tests'", .timestamp = 300 },
        .{ .command = "git push", .timestamp = 100 },
    };
    const a = arena.allocator();
    const got = try shownFor(a, &items, .all, "", "gp", 400);
    try std.testing.expectEqualStrings("git push", got[0].command);
}

test "frecency breaks a tie between equally good matches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Two commands the query fits identically well. The one run far more often
    // wins, even though the other ran more recently.
    const now: i64 = 1_000_000;
    const items = [_]Entry{
        .{ .command = "zig build once", .timestamp = now - 60, .count = 1 },
        .{ .command = "zig build often", .timestamp = now - 120, .count = 40 },
    };
    const a = arena.allocator();
    const got = try shownFor(a, &items, .all, "", "zig build", now);
    try expectShown(got, &.{ "zig build often", "zig build once" });

    // Run as rarely as the other and recency decides it again.
    const rare = [_]Entry{
        .{ .command = "zig build once", .timestamp = now - 60, .count = 1 },
        .{ .command = "zig build often", .timestamp = now - 120, .count = 1 },
    };
    try expectShown(try shownFor(a, &rare, .all, "", "zig build", now), &.{ "zig build once", "zig build often" });
}

test "an empty query leaves the list in recency order" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    // Opening the picker has to put the last command run under the selection.
    // Running something a hundred times does not move it up.
    const items = [_]Entry{
        .{ .command = "ls", .timestamp = 300, .count = 1 },
        .{ .command = "zig build", .timestamp = 100, .count = 100 },
    };
    const a = arena.allocator();
    try expectShown(try shownFor(a, &items, .all, "", "", 400), &.{ "ls", "zig build" });
    try expectShown(try shownFor(a, &items, .all, "", "   ", 400), &.{ "ls", "zig build" });
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
    try expectShown(try shownFor(a, &items, .dir, "/a", "", 10), &.{ "zig build", "ls" });
}

test "all scope collapses a command run in several directories to its newest" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const items = [_]Entry{
        .{ .command = "zig build", .cwd = "/a", .timestamp = 3, .count = 2 },
        .{ .command = "zig build", .cwd = "/b", .timestamp = 2, .count = 5 },
    };
    const got = try scoped(arena.allocator(), &items, .all, "");
    try std.testing.expectEqual(@as(usize, 1), got.len);
    try std.testing.expectEqualStrings("/a", got[0].cwd);

    // The collapsed entry carries every directory's runs, so a command you run
    // everywhere is not outranked by one you only run here.
    try std.testing.expectEqual(@as(u32, 7), got[0].count);
}

test "initialScope opens scoped only when the directory has history" {
    const items = [_]Entry{
        .{ .command = "zig build", .cwd = "/a", .timestamp = 1 },
    };
    try std.testing.expectEqual(Scope.dir, initialScope(&items, "/a"));
    try std.testing.expectEqual(Scope.all, initialScope(&items, "/fresh"));
    try std.testing.expectEqual(Scope.all, initialScope(&items, ""));
}

test "the failed command does not count as the directory having history" {
    // It is prepended with the current directory but was never stored. Counting
    // it opened a fresh directory on one row, hiding every command there was.
    const items = [_]Entry{
        .{ .command = "gti status", .cwd = "/fresh", .timestamp = 2, .failed = true },
        .{ .command = "zig build", .cwd = "/a", .timestamp = 1 },
    };
    try std.testing.expectEqual(Scope.all, initialScope(&items, "/fresh"));

    // A directory that has history of its own still opens scoped to it.
    try std.testing.expectEqual(Scope.dir, initialScope(&items, "/a"));
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
    _ = try appendEntry(a, &f, .{ .command = "ls", .timestamp = 40 }, 100, true, 80);
    try std.testing.expect(std.mem.indexOf(u8, f.items, expected) != null);
    try std.testing.expect(std.mem.indexOf(u8, f.items, sgr.reset) == f.items.len - sgr.reset.len);
}

test "the selected row reports the full width so it is never cleared back" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The frame only clears a row that stopped short. A selected row is padded
    // to the edge, so reporting less than the width would have the clear erase
    // the last cell it just painted — the bar stopping one column early.
    var sel: std.ArrayList(u8) = .empty;
    const painted = try appendEntry(a, &sel, .{ .command = "ls", .timestamp = 40 }, 100, true, 80);
    try std.testing.expectEqual(@as(usize, 80), painted);

    // A command wider than the row still reports the width, never more.
    var wide: std.ArrayList(u8) = .empty;
    const long = "cd /home/davy/cf/platform/.claude/worktrees/csd-2147 && git commit -S -C REBASE_HEAD";
    try std.testing.expectEqual(@as(usize, 80), try appendEntry(a, &wide, .{ .command = long, .timestamp = 40 }, 100, true, 80));

    // An unselected row is not padded, so it does stop short and does get
    // cleared.
    var plain: std.ArrayList(u8) = .empty;
    try std.testing.expect(try appendEntry(a, &plain, .{ .command = "ls", .timestamp = 40 }, 100, false, 80) < 80);
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
    _ = try appendEntry(a, &f, .{ .command = "ls -la", .timestamp = 40 }, 100, false, 80);
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

test "a row already in the store that is not text still draws as text" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // An image pasted into the terminal, run as the last line of a buffer whose
    // final command worked. `add` refuses these now, but one recorded before
    // that is still in the store and still has to draw.
    const pasted = "\x89PNG\n\n\nclear";
    try std.testing.expectEqualStrings("?PNG clear", try oneLine(a, pasted));

    // The collapsing path used to defang on its own and knew only about control
    // bytes, so it let this one through to the terminal raw.
    try std.testing.expect(std.unicode.utf8ValidateSlice(try oneLine(a, pasted)));
    try std.testing.expect(std.unicode.utf8ValidateSlice(try oneLine(a, "a  \xff  b")));

    // Multibyte text survives both paths intact, so the column count stays
    // exact for the rows that are text.
    try std.testing.expectEqualStrings("git log — mine", try oneLine(a, "git  log\n—  mine"));
    try std.testing.expectEqualStrings("git log — mine", try oneLine(a, "git log — mine"));
}

test "rows replace control bytes in stored commands" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    _ = try appendEntry(arena.allocator(), &f, .{ .command = "ls\x1b[31mred", .timestamp = 40 }, 100, false, 80);
    try std.testing.expect(std.mem.indexOf(u8, f.items, "ls?[31mred") != null);
}

test "the failed entry is flat red, no whetuu star, unlike a stored row" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    var buf: [style.escape_len]u8 = undefined;
    // Operator-free commands so the only source of the failure red is the entry.
    const red = try a.dupe(u8, style.sgrEscape(&buf, .{ .color = .red }));

    var failed: std.ArrayList(u8) = .empty;
    _ = try appendEntry(a, &failed, .{ .command = "gti status", .timestamp = 40, .failed = true }, 100, false, 80);
    try std.testing.expect(std.mem.indexOf(u8, failed.items, red) != null);
    try std.testing.expect(std.mem.indexOf(u8, failed.items, star) == null);

    var stored: std.ArrayList(u8) = .empty;
    _ = try appendEntry(a, &stored, .{ .command = "git status", .timestamp = 40 }, 100, false, 80);
    try std.testing.expect(std.mem.indexOf(u8, stored.items, red) == null);
    try std.testing.expect(std.mem.indexOf(u8, stored.items, star) == null);
}

test "the selected failed entry gets a red bar, not the purple one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    var failed: std.ArrayList(u8) = .empty;
    _ = try appendEntry(a, &failed, .{ .command = "gti status", .timestamp = 40, .failed = true }, 100, true, 80);
    try std.testing.expect(std.mem.indexOf(u8, failed.items, sgr.bg_red) != null);
    try std.testing.expect(std.mem.indexOf(u8, failed.items, sgr.bg_purple) == null);
}

test "a highlighted row still stops at the terminal width" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var f: std.ArrayList(u8) = .empty;
    const long = "echo 'aaaaaaaaaaaaaaaaaaaa' | grep --color bbbbbbbbbbbbbbbbbbbb";
    _ = try appendEntry(arena.allocator(), &f, .{ .command = long, .timestamp = 40 }, 100, true, 20);
    try std.testing.expectEqual(@as(usize, 20), visibleWidth(f.items));
}

/// The visible text of a tokenized command fitted to `cols`, escapes stripped.
fn fitted(arena: Allocator, command: []const u8, cols: usize) ![]const u8 {
    var f: std.ArrayList(u8) = .empty;
    _ = try appendCommand(arena, &f, try highlight.tokenize(arena, command), cols, false, null);

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
    _ = try appendCommand(a, &f, try highlight.tokenize(a, "nvim ~/.config/fish/config.fish"), 14, false, null);
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

test "Enter and Tab take the same command and differ only in what happens to it" {
    const good: Entry = .{ .command = "python3 -m http.server -d docs 8000", .cwd = "/w", .timestamp = 1 };
    const typo: Entry = .{ .command = "python3 -m http.server -d docs 8000 sdf", .cwd = "/w", .timestamp = 2, .failed = true };
    const both = [_]Entry{ typo, good };

    // A few words narrow the list and both keys take what is selected. Tab
    // hands back the entry itself, so the shell gets the whole command to edit
    // rather than the words that found it.
    try std.testing.expectEqualStrings(typo.command, accept("http.server", &both, 0, .run).?.command);
    try std.testing.expectEqualStrings(typo.command, accept("http.server", &both, 0, .edit).?.command);
    try std.testing.expectEqualStrings(good.command, accept("http.server", &both, 1, .edit).?.command);
    try std.testing.expectEqual(Action.run, accept("http.server", &both, 0, .run).?.action);
    try std.testing.expectEqual(Action.edit, accept("http.server", &both, 0, .edit).?.action);

    // No match falls back to the query, so a command typed rather than recalled
    // can be edited on the shell's line too.
    try std.testing.expectEqualStrings("git wip", accept("git wip ", &.{}, 0, .run).?.command);
    try std.testing.expectEqualStrings("git wip", accept("git wip ", &.{}, 0, .edit).?.command);

    // Neither a match nor a query is nothing to hand over.
    try std.testing.expect(accept("   ", &.{}, 0, .run) == null);
    try std.testing.expect(accept("", &.{}, 0, .edit) == null);
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
