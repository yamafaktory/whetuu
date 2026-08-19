//! Fuzzy command search. A query matches a command when every one of its
//! whitespace-separated tokens is a subsequence of it, so `gcm` finds
//! `git commit -m`. Each token is then scored by how deliberate the match looks:
//! characters found in an unbroken run, at the start of a word, or at the very
//! front of the command are worth more than the same characters found scattered
//! through the middle. A command's score is the sum over its tokens, and the
//! picker shows the best ones nearest the cursor.
//!
//! Scoring is Smith-Waterman with affine gap penalties, run over several
//! commands at once. The vectorization goes across commands rather than along
//! one. The recurrence walks left to right, so neighbouring cells of a single
//! command depend on each other and cannot be computed together, while cells of
//! eight different commands at the same position cannot depend on each other at
//! all. Every lane therefore holds a different command and the inner loop is
//! plain elementwise arithmetic, with no shuffles and no cross-lane carry.
//!
//! Two things make that layout pay, and both happen in `prepare`, which the
//! picker runs when a scope is first searched rather than on every keystroke.
//! Commands are grouped by length,
//! so lanes doing equal work never idle through the tail of one long command.
//! And each group is stored column-major — byte k of every command in it lying
//! adjacent — so the inner load is contiguous rather than a gather. `prepare`
//! also records which characters each command contains, which rejects most of a
//! store in two instructions before any of the above runs.
//!
//! Matching is over bytes, and a query is very nearly always typed ASCII. A
//! multibyte character still matches itself, byte for byte, but it is worth
//! several characters of a run rather than one.

const std = @import("std");

const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// How many commands are scored side by side. Sized to the widest vector the
/// target is known to have: whetuu is released at each target's baseline, which
/// means 128-bit vectors (SSE2 on x86_64, NEON on aarch64) and so eight u16
/// lanes. A target with wider registers gets wider groups for free.
const lanes = std.simd.suggestVectorLength(u16) orelse 8;

/// One score per lane. u16 holds far more than the longest command can earn.
const Scores = @Vector(lanes, u16);

/// One byte per lane, the shape a column of the transposed group loads as.
const Bytes = @Vector(lanes, u8);

const Mask = @Vector(lanes, u64);
const Flags = @Vector(lanes, bool);

/// What one matched character is worth before bonuses.
const match_score: u16 = 16;

/// Skipping a command character costs this much to start doing.
const gap_open: u16 = 3;

/// And this much to keep doing, so one long gap beats several short ones — a
/// query is usually a few words with the noise between them elided, not a
/// character sprinkled every few positions.
const gap_extend: u16 = 1;

/// Matching the first character of a word: after a separator, or after a
/// lowercase letter in `camelCase`, or at the very front of the command.
const bonus_boundary: u16 = 8;
const bonus_camel: u16 = 7;
const bonus_first: u16 = 12;

/// Matching immediately after the previous character matched. Taken as the
/// larger of this and the position bonus rather than added to it, so a run
/// through the middle of a word cannot out-score one that also starts a word.
const bonus_consecutive: u16 = 8;

/// A cell holds 0 when the query cannot have been matched this far, and its
/// score otherwise — which is why a reachable cell never decays to 0 however
/// much gap it has crossed, and why matching starts from 1 rather than 0.
const unreachable_cell: u16 = 0;
const reachable_floor: u16 = 1;
const start_base: u16 = 1;

/// Group widths. A command is padded up to the next of these; one longer than
/// the largest is scored on its first `max_width` bytes, which is far past the
/// point where a longer command tells you anything a query was aiming at.
const widths = [_]usize{ 16, 32, 64, 128 };
const max_width = widths[widths.len - 1];

/// One group of up to `lanes` commands of the same padded width, laid out for
/// the scoring loop to read a column at a time.
const Group = struct {
    /// Lowercased command bytes, column-major: byte `k` of lane `j` at
    /// `bytes[k * lanes + j]`. Padding is 0, which no command byte and no query
    /// byte can be, so a padded lane matches nothing.
    bytes: []const u8,
    /// Position bonuses in the same layout, computed from the original case.
    bonus: []const u8,
    /// The characters each lane's command contains, for the prefilter. A lane
    /// holding no command has none, so it fails every non-empty query.
    mask: [lanes]u64,
    /// Which command each lane holds. Only the first `live` are meaningful.
    index: [lanes]u32,
    live: usize,
    width: usize,

    /// Whether any lane's command contains every character of the query, which
    /// is a necessary condition for matching it. Cheap enough to run over a
    /// whole store per keystroke, and it typically leaves a few hundred groups
    /// of the thousands there are.
    fn admits(group: Group, wanted: u64) bool {
        const have: Mask = group.mask;
        const want: Mask = @splat(wanted);
        return @reduce(.Or, (have & want) == want);
    }
};

/// A set of commands prepared for scoring. Built once per scope, then queried
/// on every keystroke.
pub const Corpus = struct {
    pub const empty: Corpus = .{ .groups = &.{}, .len = 0 };

    groups: []const Group,
    /// How many commands were prepared, which is the length `scoreAll` writes.
    len: usize,

    /// Groups `commands` by length and transposes each group into the layout
    /// the scoring loop reads. Costs about what reading the store costs, which
    /// is why the picker holds it back until something is actually typed. Every
    /// allocation lives as long as the corpus, so pass the arena that is reset
    /// when the scope changes.
    pub fn prepare(arena: Allocator, commands: []const []const u8) Allocator.Error!Corpus {
        var buckets: [widths.len]std.ArrayList(u32) = @splat(.empty);
        for (commands, 0..) |command, i| {
            try buckets[bucketOf(command.len)].append(arena, @intCast(i));
        }

        var groups: std.ArrayList(Group) = .empty;
        for (&buckets, widths) |bucket, width| {
            var at: usize = 0;
            while (at < bucket.items.len) : (at += lanes) {
                const members = bucket.items[at..@min(at + lanes, bucket.items.len)];
                try groups.append(arena, try buildGroup(arena, commands, members, width));
            }
        }

        return .{ .groups = try groups.toOwnedSlice(arena), .len = commands.len };
    }

    /// Writes each command's score into `out`, 0 for the ones the query does
    /// not match. `out` is indexed exactly as the `commands` slice `prepare`
    /// was given, and must be that long.
    ///
    /// An empty query matches everything with a flat score, leaving the caller
    /// to keep whatever order it already had.
    pub fn scoreAll(corpus: Corpus, scratch: Allocator, query: []const u8, out: []u16) Allocator.Error!void {
        assert(out.len == corpus.len);
        @memset(out, 1);

        var rows: Rows = try .init(scratch);
        var token_scores: ?[]u16 = null;
        var first = true;

        var it = std.mem.tokenizeAny(u8, query, " \t");
        while (it.next()) |token| {
            const needle = try lowered(scratch, token);
            if (first) {
                corpus.scoreToken(needle, &rows, out);
                first = false;
                continue;
            }

            // Later tokens score into their own buffer, because a command has
            // to match all of them: one miss drops it however well the rest of
            // the query fitted.
            const scores = token_scores orelse try scratch.alloc(u16, out.len);
            token_scores = scores;
            corpus.scoreToken(needle, &rows, scores);
            for (out, scores) |*total, score| {
                total.* = if (total.* == 0 or score == 0) 0 else total.* +| score;
            }
        }
    }

    /// Scores one token, writing 0 for every command it does not match.
    fn scoreToken(corpus: Corpus, needle: []const u8, rows: *Rows, out: []u16) void {
        @memset(out, 0);
        if (needle.len == 0 or needle.len > max_width) return;

        const wanted = charsOf(needle);
        for (corpus.groups) |group| {
            // A command shorter than the query cannot contain it, and a group
            // none of whose commands hold every query character cannot match.
            if (needle.len > group.width or !group.admits(wanted)) continue;

            const best: [lanes]u16 = scoreGroup(group, needle, rows);
            for (best[0..group.live], group.index[0..group.live]) |score, at| out[at] = score;
        }
    }
};

/// The two rows the recurrence keeps: the scores of the previous query
/// character, and which of those cells were matches rather than gaps.
///
/// Both are needed because the consecutive bonus asks whether the cell up and
/// to the left was itself a match, which a score alone cannot answer.
const Rows = struct {
    h_prev: []Scores,
    h_cur: []Scores,
    m_prev: []Scores,
    m_cur: []Scores,

    fn init(scratch: Allocator) Allocator.Error!Rows {
        return .{
            .h_prev = try scratch.alloc(Scores, max_width),
            .h_cur = try scratch.alloc(Scores, max_width),
            .m_prev = try scratch.alloc(Scores, max_width),
            .m_cur = try scratch.alloc(Scores, max_width),
        };
    }

    fn swap(rows: *Rows) void {
        std.mem.swap([]Scores, &rows.h_prev, &rows.h_cur);
        std.mem.swap([]Scores, &rows.m_prev, &rows.m_cur);
    }
};

/// Scores one group's commands against `needle`, returning the best score each
/// lane reached. A lane holding no command, or one the needle does not match,
/// comes back 0.
///
/// The row before the first is every cell reachable at `start_base` and no cell
/// a match, which is what lets the query begin at any position of the command
/// without letting it restart partway through: past the first query character a
/// cell can only be reached from a cell that was itself reached.
fn scoreGroup(group: Group, needle: []const u8, rows: *Rows) Scores {
    const zero: Scores = @splat(unreachable_cell);
    const consecutive: Scores = @splat(bonus_consecutive);
    const match: Scores = @splat(match_score);
    const width = group.width;

    @memset(rows.h_prev[0..width], @splat(start_base));
    @memset(rows.m_prev[0..width], zero);

    for (needle, 0..) |char, row| {
        const wanted: Scores = @splat(char);
        // Column -1 of the row above: reachable only before the query has
        // started, since no prefix of it can have been matched left of the
        // command's first character.
        const edge: Scores = if (row == 0) @splat(start_base) else zero;
        var left = zero;
        var gap = zero;

        for (0..width) |k| {
            const diag_h = if (k == 0) edge else rows.h_prev[k - 1];
            const diag_m = if (k == 0) zero else rows.m_prev[k - 1];
            const here = column(group.bytes, k);
            const bonus = column(group.bonus, k);

            // The character matches and the query was matched up to here, so
            // this cell continues that alignment.
            const hit = both(here == wanted, diag_h != zero);
            const gain = @select(u16, diag_m != zero, @max(bonus, consecutive), bonus) + match;
            const m = @select(u16, hit, diag_h +| gain, zero);

            // Or the character is skipped, which costs more to start than to
            // carry on doing.
            gap = @max(decayed(left, gap_open), decayed(gap, gap_extend));

            const h = @max(m, gap);
            rows.h_cur[k] = h;
            rows.m_cur[k] = m;
            left = h;
        }

        rows.swap();
    }

    // The swap leaves the last query character's row in `h_prev`. Its best cell
    // is the score, since reaching it means every character was matched.
    var best = zero;
    for (rows.h_prev[0..width]) |h| best = @max(best, h);
    return best;
}

/// Column `k` of a transposed group, widened to the score type the recurrence
/// works in.
fn column(buf: []const u8, k: usize) Scores {
    const bytes: Bytes = buf[k * lanes ..][0..lanes].*;
    return @intCast(bytes);
}

/// Elementwise `a and b`, which vectors of bools express as a select rather
/// than as the operator.
fn both(a: Flags, b: Flags) Flags {
    return @select(bool, a, b, @as(Flags, @splat(false)));
}

/// A gap path one character longer: still reachable, and cheaper the further it
/// already ran. Never decays to `unreachable_cell`, which means something else.
fn decayed(scores: Scores, cost: u16) Scores {
    const floor: Scores = @splat(reachable_floor);
    const worse = @max(scores -| @as(Scores, @splat(cost)), floor);
    return @select(u16, scores != @as(Scores, @splat(unreachable_cell)), worse, @as(Scores, @splat(unreachable_cell)));
}

/// Lays out up to `lanes` commands column-major, padded to `width`, alongside
/// the position bonuses and character sets that never change between
/// keystrokes.
fn buildGroup(arena: Allocator, commands: []const []const u8, members: []const u32, width: usize) Allocator.Error!Group {
    assert(members.len > 0 and members.len <= lanes);

    const bytes = try arena.alloc(u8, width * lanes);
    @memset(bytes, 0);
    const bonus = try arena.alloc(u8, width * lanes);
    @memset(bonus, 0);

    var mask: [lanes]u64 = @splat(0);
    var index: [lanes]u32 = @splat(0);
    for (members, 0..) |command_index, lane| {
        const command = commands[command_index];
        const scored = command[0..@min(command.len, width)];
        index[lane] = command_index;
        mask[lane] = charsOf(scored);
        if (scored.len == 0) continue;

        // Position 0 has no character before it to read a bonus from, so it is
        // written outside the loop rather than branched on inside it.
        bytes[lane] = std.ascii.toLower(scored[0]);
        bonus[lane] = bonus_first;
        for (scored[1..], 1..) |char, k| {
            bytes[k * lanes + lane] = std.ascii.toLower(char);
            bonus[k * lanes + lane] = positionBonus(scored[k - 1], char);
        }
    }

    return .{
        .bytes = bytes,
        .bonus = bonus,
        .mask = mask,
        .index = index,
        .live = members.len,
        .width = width,
    };
}

/// The four kinds of character a bonus can depend on.
const Kind = enum(u2) { other, lower, upper, digit };

/// Every byte's kind, so classifying one is a load rather than a chain of range
/// checks. Built at compile time.
const kinds: [256]Kind = blk: {
    var table: [256]Kind = @splat(.other);
    for (&table, 0..) |*kind, char| {
        kind.* = if (std.ascii.isLower(char))
            .lower
        else if (std.ascii.isUpper(char))
            .upper
        else if (std.ascii.isDigit(char))
            .digit
        else
            .other;
    }
    break :blk table;
};

/// What matching at a position is worth on its own, by the kinds of the
/// character before it and the character itself. Anything after a separator
/// starts a word; inside one, only a `camelCase` hump or the first digit of a
/// number does.
///
/// A table rather than a chain of tests because this runs on every byte of
/// every command each time a scope is prepared, and the tests do not predict:
/// which branch a byte takes depends on the byte.
const bonuses: [4][4]u8 = blk: {
    var table: [4][4]u8 = @splat(@splat(0));
    for (std.enums.values(Kind)) |before| {
        for (std.enums.values(Kind)) |char| {
            const opens_word = switch (before) {
                .other => true,
                .lower => char == .upper or char == .digit,
                .upper => char == .digit,
                .digit => false,
            };
            table[@intFromEnum(before)][@intFromEnum(char)] = switch (before) {
                .other => bonus_boundary,
                else => if (opens_word) bonus_camel else 0,
            };
        }
    }
    break :blk table;
};

/// The bonus for the character at `char`, given the one before it. Case matters
/// here and nowhere else, which is why it is read before the bytes are
/// lowercased.
fn positionBonus(prev: u8, char: u8) u8 {
    return bonuses[@intFromEnum(kinds[prev])][@intFromEnum(kinds[char])];
}

/// The set of characters `text` contains, as one bit each. Letters and digits
/// get a bit to themselves and everything else shares, which costs the
/// prefilter a few false positives on punctuation and no false negatives at
/// all.
fn charsOf(text: []const u8) u64 {
    var mask: u64 = 0;
    for (text) |char| mask |= @as(u64, 1) << charBit(std.ascii.toLower(char));
    return mask;
}

fn charBit(lower: u8) u6 {
    if (lower >= 'a' and lower <= 'z') return @intCast(lower - 'a');
    if (lower >= '0' and lower <= '9') return @intCast(26 + lower - '0');
    return @intCast(36 + lower % 28);
}

/// The bucket a command of this length is padded into.
fn bucketOf(len: usize) usize {
    for (widths, 0..) |width, i| {
        if (len <= width) return i;
    }
    return widths.len - 1;
}

/// A lowercased copy, since the query is matched case-insensitively and the
/// command bytes were lowercased when the corpus was prepared.
fn lowered(scratch: Allocator, text: []const u8) Allocator.Error![]const u8 {
    const out = try scratch.alloc(u8, text.len);
    for (text, out) |char, *slot| slot.* = std.ascii.toLower(char);
    return out;
}

/// Whether `command` matches `query` at all, every token of it as a
/// subsequence. The scoring path answers this too, by returning 0, but the
/// question is worth asking on its own for a single command.
pub fn matches(command: []const u8, query: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, query, " \t");
    while (it.next()) |token| {
        if (!isSubsequence(command, token)) return false;
    }

    return true;
}

fn isSubsequence(command: []const u8, token: []const u8) bool {
    var at: usize = 0;
    for (token) |char| {
        const lower = std.ascii.toLower(char);
        while (at < command.len and std.ascii.toLower(command[at]) != lower) at += 1;
        if (at == command.len) return false;
        at += 1;
    }

    return true;
}

const hour = 60 * 60;
const day = 24 * hour;
const week = 7 * day;
const month = 30 * day;

/// How hard a command's past use pulls it up when two commands match a query
/// equally well: how often it was run, weighted by how recently. Only ever a
/// tiebreak — a command that fits what you typed better is always shown first,
/// however long ago you last ran it.
///
/// `count` is how many times the command appears in the window a load reads,
/// so this is frequency over recent history rather than over all time. A
/// command with no timestamp (a line written before whetuu recorded them) ages
/// out to the lowest weight rather than being dropped.
pub fn frecency(count: u32, age: i64) u32 {
    const weight: u32 = if (age < hour)
        100
    else if (age < day)
        50
    else if (age < week)
        25
    else if (age < month)
        10
    else
        1;

    return count *| weight;
}

/// The score `command` gets for `query`, for tests that care about one command.
fn scoreOne(arena: Allocator, command: []const u8, query: []const u8) !u16 {
    const corpus: Corpus = try .prepare(arena, &.{command});
    var out: [1]u16 = undefined;
    try corpus.scoreAll(arena, query, &out);
    return out[0];
}

/// Asserts that `better` outranks `worse` for `query`, and that both match.
fn expectRanksAbove(query: []const u8, better: []const u8, worse: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const high = try scoreOne(a, better, query);
    const low = try scoreOne(a, worse, query);
    try std.testing.expect(high > 0);
    try std.testing.expect(low > 0);
    try std.testing.expect(high > low);
}

test "a query matches as a subsequence, not only as a substring" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expect(try scoreOne(a, "git commit -m 'fix'", "gcm") > 0);
    try std.testing.expect(try scoreOne(a, "git checkout main", "gcm") > 0);
    try std.testing.expect(try scoreOne(a, "zig build --release=fast", "gcm") == 0);

    // Order still counts: the characters have to appear in the order typed.
    try std.testing.expect(try scoreOne(a, "git commit", "mcg") == 0);
}

test "a run beats the same characters scattered" {
    try expectRanksAbove("push", "git push origin", "p u s h everywhere");
    try expectRanksAbove("build", "zig build", "b u i l d apart");
}

test "matching the start of a word beats matching the middle of one" {
    try expectRanksAbove("p", "git push", "shampoo");
    try expectRanksAbove("rf", "rm -rf", "surf reef");
}

test "matching the front of a command beats matching further in" {
    try expectRanksAbove("git", "git status", "echo git");
}

test "a camelCase hump and a digit both start a word" {
    try expectRanksAbove("gp", "gitPush", "gxxxpxxx");

    // The digit that opens a run of them starts a word; one partway through a
    // number does not.
    try expectRanksAbove("l3", "level3", "l12345");
}

test "every token of a query has to match" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expect(try scoreOne(a, "git push origin", "git pu") > 0);
    try std.testing.expect(try scoreOne(a, "git push origin", "git pull") == 0);
    try std.testing.expect(try scoreOne(a, "git push origin", "git nope") == 0);

    // Two tokens that both match score above either alone, so a command hit by
    // the whole query outranks one hit by half of it.
    const both_tokens = try scoreOne(a, "git push origin", "git push");
    try std.testing.expect(both_tokens > try scoreOne(a, "git push origin", "git"));
}

test "matching ignores case in both directions" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    try std.testing.expect(try scoreOne(a, "GIT PUSH", "git push") > 0);
    try std.testing.expect(try scoreOne(a, "git push", "GIT PUSH") > 0);
}

test "an empty query matches everything and ranks nothing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    const a = arena.allocator();
    const commands = [_][]const u8{ "git push", "ls", "zig build" };
    const corpus: Corpus = try .prepare(a, &commands);

    var out: [3]u16 = undefined;
    try corpus.scoreAll(a, "   ", &out);
    try std.testing.expectEqualSlices(u16, &.{ 1, 1, 1 }, &out);
}

test "the corpus scores a command the same wherever it sits in a group" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Groups hold `lanes` commands, so a corpus this size has a full group and
    // a partial one. Padding a lane that holds no command must not leak into
    // the lanes beside it, and a command must score the same in either.
    const filler = "unrelated filler command";
    var commands: std.ArrayList([]const u8) = .empty;
    for (0..lanes * 2 + 3) |_| try commands.append(a, filler);
    const target = "git commit --amend";
    try commands.append(a, target);

    const corpus: Corpus = try .prepare(a, commands.items);
    const scores = try a.alloc(u16, commands.items.len);
    try corpus.scoreAll(a, "gca", scores);

    try std.testing.expectEqual(try scoreOne(a, target, "gca"), scores[scores.len - 1]);
    for (scores[0 .. scores.len - 1]) |score| try std.testing.expectEqual(@as(u16, 0), score);
}

test "commands of every length are scored, including past the widest group" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // One command per length either side of every group boundary, each ending
    // in the query so only a command that is actually scanned can match.
    var commands: std.ArrayList([]const u8) = .empty;
    var len: usize = 1;
    while (len <= max_width + 40) : (len += 1) {
        const padding = try a.alloc(u8, len);
        @memset(padding, 'x');
        try commands.append(a, try std.fmt.allocPrint(a, "{s}zig", .{padding}));
    }

    const corpus: Corpus = try .prepare(a, commands.items);
    const scores = try a.alloc(u16, commands.items.len);
    try corpus.scoreAll(a, "zig", scores);

    for (scores, commands.items) |score, command| {
        // Only what fits in the scored prefix can match, and everything that
        // fits must.
        const reachable = command.len <= max_width;
        try std.testing.expectEqual(reachable, score > 0);
    }
}

/// Scores one command against one token the slow, obvious way: every
/// subsequence considered, the best one kept. Exponential, so tests feed it
/// short strings only.
fn referenceScore(command: []const u8, token: []const u8) u16 {
    return walk(command, token, 0, 0, start_base, false);
}

fn walk(command: []const u8, token: []const u8, at: usize, taken: usize, score: u16, after_match: bool) u16 {
    if (taken == token.len) return score;
    if (at == command.len) return 0;

    // Skip this command character.
    var best: u16 = if (score == unreachable_cell) 0 else walk(command, token, at + 1, taken, score, false);

    if (std.ascii.toLower(command[at]) == std.ascii.toLower(token[taken])) {
        const bonus: u16 = if (at == 0) bonus_first else positionBonus(command[at - 1], command[at]);
        const gain = match_score + if (after_match) @max(bonus, bonus_consecutive) else bonus;
        best = @max(best, walk(command, token, at + 1, taken + 1, score +| gain, true));
    }

    return best;
}

test "the vectorized score agrees with the obvious one" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // The reference ignores gap penalties, so it can only be compared where no
    // gap is crossed after the first match — which is what an unbroken run is.
    // These are all runs, of the kinds the bonuses are meant to separate.
    const cases = [_]struct { command: []const u8, token: []const u8 }{
        .{ .command = "git push", .token = "git" },
        .{ .command = "git push", .token = "push" },
        .{ .command = "gitPush", .token = "push" },
        .{ .command = "cargo test", .token = "test" },
        .{ .command = "level3 up", .token = "3" },
        .{ .command = "rm -rf /tmp", .token = "rf" },
        .{ .command = "ZIG BUILD", .token = "build" },
        .{ .command = "a-b-c", .token = "c" },
    };

    for (cases) |case| {
        const got = try scoreOne(a, case.command, case.token);
        try std.testing.expectEqual(referenceScore(case.command, case.token), got);
    }
}

test "the prefilter never rejects a command that matches" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // Every command in one corpus, so the prefilter is what decides which
    // groups the scoring loop even looks at. Anything the plain subsequence
    // test calls a match has to come back with a score.
    const commands = [_][]const u8{
        "git push origin main",
        "git commit -m 'fix the thing'",
        "zig build --release=fast",
        "cd ~/dev/whetuu && zig build test",
        "ls -la",
        "docker compose up -d",
        "rm -rf zig-out .zig-cache",
        "curl -fsSL https://example.com | sh",
        "echo $PATH",
        "nvim ~/.config/fish/config.fish",
    };
    const queries = [_][]const u8{ "g", "gp", "zb", "zig", "rf", "cd whetuu", "config", "up -d", "xyz", "git push" };

    const corpus: Corpus = try .prepare(a, &commands);
    const scores = try a.alloc(u16, commands.len);
    for (queries) |query| {
        try corpus.scoreAll(a, query, scores);
        for (commands, scores) |command, score| {
            try std.testing.expectEqual(matches(command, query), score > 0);
        }
    }
}

test "matches agrees with scoring on whether a query matches at all" {
    try std.testing.expect(matches("git commit -m", "gcm"));
    try std.testing.expect(matches("git push origin", "git pu"));
    try std.testing.expect(!matches("git push origin", "git pull"));
    try std.testing.expect(matches("anything", ""));
    try std.testing.expect(!matches("", "x"));
}

test "frecency weighs how often against how recently" {
    // More runs wins at the same age.
    try std.testing.expect(frecency(9, day + 1) > frecency(3, day + 1));

    // And a recent command wins over an older one run as often.
    try std.testing.expect(frecency(3, 60) > frecency(3, week + 1));

    // A command with no timestamp reads as ancient rather than as an error.
    try std.testing.expect(frecency(1, std.math.maxInt(i32)) > 0);

    // A clock that ran backwards leaves a future timestamp, which is recent.
    try std.testing.expectEqual(frecency(1, 0), frecency(1, -500));
}

test "the prefilter never rejects a command the subsequence test accepts" {
    const Context = struct {
        fn testOne(_: @This(), smith: *std.testing.Smith) anyerror!void {
            var command_buf: [max_width]u8 = undefined;
            var query_buf: [32]u8 = undefined;
            const command = command_buf[0..smith.slice(&command_buf)];
            const query = query_buf[0..smith.slice(&query_buf)];
            for (query) |*c| c.* = 0x20 + (c.* % 0x5f);

            var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer arena.deinit();
            const a = arena.allocator();

            const corpus: Corpus = try .prepare(a, &.{command});
            var out: [1]u16 = undefined;
            try corpus.scoreAll(a, query, &out);
            try std.testing.expectEqual(matches(command, query), out[0] > 0);
        }
    };
    return std.testing.fuzz(Context{}, Context.testOne, .{});
}
