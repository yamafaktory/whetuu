//! whetuu entry point. Four subcommands:
//!   whetuu init <fish|bash|zsh>   — print the shell integration script
//!   whetuu render [flags]         — render the status line (called by the shell)
//!   whetuu history [add ...]      — open the history picker, or record a command
//!   whetuu paths                  — print where the history and cache live
//! plus `whetuu --version`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const build_options = @import("build_options");

const Env = @import("Env.zig");
const cli = @import("cli.zig");
const history = @import("history.zig");
const init_scripts = @import("init_scripts.zig");
const picker = @import("picker.zig");
const render = @import("render.zig");
const style = @import("style.zig");
const version_cache = @import("version_cache.zig");

/// Upper bound on a current-directory path. Beyond this the directory is simply
/// reported empty rather than overrunning the buffer.
const max_path_bytes = 4096;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) return usage(io);

    const sub = args[1];
    if (std.mem.eql(u8, sub, "--version") or std.mem.eql(u8, sub, "-v")) {
        return writeVersion(io);
    }

    if (std.mem.eql(u8, sub, "init")) {
        if (args.len < 3) return usage(io);
        return init_scripts.write(io, args[2]);
    }

    if (std.mem.eql(u8, sub, "render")) {
        return runRender(io, arena, init.environ_map, args[2..]);
    }

    if (std.mem.eql(u8, sub, "history")) {
        return runHistory(io, arena, init.environ_map, args[2..]);
    }

    if (std.mem.eql(u8, sub, "paths")) {
        return runPaths(io, arena, init.environ_map);
    }

    return unknownSubcommand(io, arena, sub);
}

/// One line and a failing status for a subcommand that does not exist, rather
/// than the whole command list.
///
/// The shell hook runs whetuu before every command, so this is not only what a
/// typo hits. A shell started before an upgrade keeps calling whatever the
/// integration script said when the session began, and if that subcommand has
/// since been renamed, every prompt lands here. Printing the command list then
/// buries the terminal in it once per command. One line names what was called,
/// which is the thing worth knowing, and a non-zero status lets a caller tell
/// this apart from an empty render.
fn unknownSubcommand(io: Io, arena: Allocator, sub: []const u8) !void {
    var buf: [512]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &buf);

    // Straight off the command line, so it can hold anything at all. Nothing
    // reaches the terminal without going through `sanitize` first.
    const safe = try style.sanitize(arena, sub);
    try fw.interface.print(
        "whetuu: no such command {s}{s}{s}. Run {s}whetuu{s} for the list.\n",
        .{ style.sgr.bold, safe, style.sgr.reset, style.sgr.fg_purple, style.sgr.reset },
    );
    try fw.interface.flush();

    std.process.exit(2);
}

/// Prints where whetuu keeps its two files, and whether each exists yet.
/// Both follow the XDG base directory spec, so neither is under the directory
/// the installer put the binary in: removing whetuu should not remove the
/// history you built up with it.
fn runPaths(io: Io, arena: Allocator, environ: *std.process.Environ.Map) !void {
    const home = environ.get("HOME") orelse "";
    const store = try history.storePath(arena, environ.get("XDG_DATA_HOME") orelse "", home);
    const cache = try version_cache.path(arena, environ.get("XDG_CACHE_HOME") orelse "", home);

    var buf: [1024]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    const w = &fw.interface;

    try w.writeAll(style.sgr.fg_purple ++ style.icon.star ++ style.sgr.reset ++ " " ++
        style.sgr.dim ++ "whetuu keeps two files, both outside the install directory" ++
        style.sgr.reset ++ "\n\n");
    try writePath(io, w, "history", store);
    try writePath(io, w, "cache", cache);
    try w.flush();
}

/// One `<label>  <path>  <state>` row. A null path means neither `$HOME` nor
/// the matching XDG variable was set, so whetuu has nowhere to write.
fn writePath(io: Io, w: *std.Io.Writer, label: []const u8, path: ?[]const u8) !void {
    const dim = style.sgr.dim;
    const reset = style.sgr.reset;

    try w.print("  " ++ dim ++ "{s: <8}" ++ reset, .{label});
    const p = path orelse {
        try w.writeAll(dim ++ "unset, no HOME or XDG variable" ++ reset ++ "\n");
        return;
    };

    try w.writeAll(p);
    if (Io.Dir.accessAbsolute(io, p, .{})) |_| {} else |_| {
        try w.writeAll("  " ++ dim ++ "(not created yet)" ++ reset);
    }
    try w.writeByte('\n');
}

/// Builds the `Env` from flags and environment, then renders to stdout.
fn runRender(io: Io, arena: Allocator, environ: *std.process.Environ.Map, args: []const [:0]const u8) !void {
    const opts = try cli.parseRender(args);

    var cwd_buf: [max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;

    const env: Env = .{
        .shell = opts.shell,
        .cwd = cwd_buf[0..cwd_len],
        .home = environ.get("HOME") orelse "",
        .user = environ.get("USER") orelse "",
        .path = environ.get("PATH") orelse "",
        .cache_home = environ.get("XDG_CACHE_HOME") orelse "",
        .ssh = environ.get("SSH_CONNECTION") != null or environ.get("SSH_TTY") != null,
        .width = opts.width,
        .duration_ms = opts.duration_ms,
        .exit_status = opts.exit_status,
    };

    var out_buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &out_buf);
    try render.render(io, arena, &env, &fw.interface);
    try fw.interface.flush();
}

/// Handles the `history` subcommand: `history add [--status N] -- <command>`
/// records a command (dropped unless its exit status is 0, so only commands
/// that ran successfully are stored), while `history [--query <text>]
/// [--last <command>]` opens the interactive picker — seeded with `text`, the
/// shell's current command line — and prints the chosen command to stdout for
/// the shell to place on the command line. `--last` is the command that just
/// failed, shown marked at the top and never stored, so the thing that broke
/// can be recalled without cluttering the store.
fn runHistory(io: Io, arena: Allocator, environ: *std.process.Environ.Map, args: []const [:0]const u8) !void {
    const xdg = environ.get("XDG_DATA_HOME") orelse "";
    const home = environ.get("HOME") orelse "";
    const path = (try history.storePath(arena, xdg, home)) orelse return;

    // The process inherits the shell's working directory, so recording and
    // scoping need no extra flag from the init scripts.
    var cwd_buf: [max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;
    const cwd = cwd_buf[0..cwd_len];

    if (args.len > 0 and std.mem.eql(u8, args[0], "add")) {
        const opts = try cli.parseHistoryAdd(args[1..]);
        if (opts.exit_status != 0) return;

        const parts = try arena.alloc([]const u8, opts.words.len);
        for (opts.words, parts) |word, *part| part.* = word;
        return history.add(io, arena, path, try std.mem.join(arena, " ", parts), cwd, unixNow(io));
    }

    const opts = try cli.parseHistoryPick(args);
    const loaded = try history.load(io, arena, path);
    // The failure keeps the time it ran, so its age counts up across picker
    // opens instead of resetting to zero each time. A missing stamp means now.
    const failed_at = if (opts.last_at > 0) opts.last_at else unixNow(io);
    const items = try withLastFailure(arena, loaded, opts.last, cwd, failed_at);
    const chosen = picker.pick(io, arena, items, .{ .initial = opts.query, .cwd = cwd, .home = home }) orelse return;

    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(chosen);
    try fw.interface.writeByte('\n');
    try fw.interface.flush();
}

/// Prepends the just-failed command as an ephemeral, most-recent entry the
/// picker marks and never stores, so the command that just broke can be picked
/// and edited without cluttering the store. A stored duplicate in the same
/// directory is dropped so the command appears once, marked. An empty or
/// whitespace-only `last` — no failure, or the shell's slot was clear — returns
/// `loaded` untouched.
fn withLastFailure(arena: Allocator, loaded: []const history.Entry, last: []const u8, cwd: []const u8, failed_at: i64) ![]const history.Entry {
    const command = std.mem.trim(u8, last, " \t\r\n");
    if (command.len == 0) return loaded;

    var out: std.ArrayList(history.Entry) = .empty;
    try out.ensureTotalCapacity(arena, loaded.len + 1);
    out.appendAssumeCapacity(.{ .command = command, .cwd = cwd, .timestamp = failed_at, .failed = true });
    for (loaded) |entry| {
        if (std.mem.eql(u8, entry.cwd, cwd) and std.mem.eql(u8, entry.command, command)) continue;
        out.appendAssumeCapacity(entry);
    }
    return out.toOwnedSlice(arena);
}

/// Current wall-clock time as unix seconds, used to stamp and age history.
fn unixNow(io: Io) i64 {
    return Io.Clock.now(.real, io).toSeconds();
}

/// Prints the vertical, colorized help to stderr: the star emblem and command
/// names in the whetuu brand purple, descriptions dimmed, one entry per line.
/// The wordmark is deliberately absent — the status line right above the
/// output already shows it — and so are the flags of `render` and `history add`,
/// which only the shell init scripts ever pass.
fn usage(io: Io) !void {
    const bold = style.sgr.bold;
    const dim = style.sgr.dim;
    const purple = style.sgr.fg_purple;
    const reset = style.sgr.reset;

    const text =
        purple ++ style.icon.star ++ reset ++ " " ++
        dim ++ "opinionated, zero-config, async status line and history picker" ++ reset ++ "\n" ++
        "\n" ++
        bold ++ "Commands" ++ reset ++ "\n" ++
        "  " ++ purple ++ "init" ++ reset ++ " <fish|bash|zsh>   " ++ dim ++ "Print the shell integration script" ++ reset ++ "\n" ++
        "  " ++ purple ++ "render" ++ reset ++ "                 " ++ dim ++ "Render the status line (called by the shell)" ++ reset ++ "\n" ++
        "  " ++ purple ++ "history" ++ reset ++ "                " ++ dim ++ "Open the interactive history picker" ++ reset ++ "\n" ++
        "  " ++ purple ++ "history add" ++ reset ++ "            " ++ dim ++ "Record a finished command (status 0 only)" ++ reset ++ "\n" ++
        "  " ++ purple ++ "paths" ++ reset ++ "                  " ++ dim ++ "Print where the history and cache live" ++ reset ++ "\n" ++
        "  " ++ purple ++ "--version" ++ reset ++ "              " ++ dim ++ "Print the version" ++ reset ++ "\n";

    var buf: [256]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &buf);
    try fw.interface.writeAll(text);
    try fw.interface.flush();
}

/// Prints the version to stdout, so `whetuu --version` stays pipeable while the
/// help above goes to stderr.
fn writeVersion(io: Io) !void {
    var buf: [64]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(build_options.version);
    try fw.interface.writeByte('\n');
    try fw.interface.flush();
}

test {
    _ = @import("Env.zig");
    _ = @import("cli.zig");
    _ = @import("highlight.zig");
    _ = @import("history.zig");
    _ = @import("init_scripts.zig");
    _ = @import("picker.zig");
    _ = @import("module_character.zig");
    _ = @import("module_cmd_duration.zig");
    _ = @import("module_directory.zig");
    _ = @import("module_git.zig");
    _ = @import("module_language.zig");
    _ = @import("module_user_host.zig");
    _ = @import("render.zig");
    _ = @import("style.zig");
    _ = @import("time_ago.zig");
    _ = @import("version_cache.zig");
}

test "paths reports both files, and says so when there is nowhere to write" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // XDG wins over HOME, and both land under a whetuu directory of their own
    // rather than under the directory the installer used.
    try std.testing.expectEqualStrings("/xd/whetuu/history", (try history.storePath(a, "/xd", "/h")).?);
    try std.testing.expectEqualStrings("/xc/whetuu/versions", (try version_cache.path(a, "/xc", "/h")).?);
    try std.testing.expectEqualStrings("/h/.local/share/whetuu/history", (try history.storePath(a, "", "/h")).?);
    try std.testing.expectEqualStrings("/h/.cache/whetuu/versions", (try version_cache.path(a, "", "/h")).?);

    // whetuu creates no directory of its own in $HOME, so removing the binary
    // from ~/.local/bin cannot take the history with it, and an uninstall has
    // only paths the XDG spec already names to clean up.
    for ([_][]const u8{
        (try history.storePath(a, "", "/h")).?,
        (try version_cache.path(a, "", "/h")).?,
    }) |path| {
        try std.testing.expect(std.mem.startsWith(u8, path, "/h/.local/share/") or
            std.mem.startsWith(u8, path, "/h/.cache/"));
    }

    try std.testing.expect((try history.storePath(a, "", "")) == null);
    try std.testing.expect((try version_cache.path(a, "", "")) == null);
}

test "withLastFailure prepends the failure once, marked, dropping a same-dir duplicate" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    const loaded = [_]history.Entry{
        .{ .command = "zig build", .cwd = "/w", .timestamp = 20 },
        .{ .command = "ls", .cwd = "/w", .timestamp = 10 },
    };

    // The failed command sits first, marked, and its earlier success in the same
    // directory is dropped so it appears once.
    const with = try withLastFailure(a, &loaded, "zig build", "/w", 30);
    try std.testing.expectEqual(@as(usize, 2), with.len);
    try std.testing.expectEqualStrings("zig build", with[0].command);
    try std.testing.expect(with[0].failed);
    try std.testing.expectEqual(@as(i64, 30), with[0].timestamp);
    try std.testing.expectEqualStrings("ls", with[1].command);

    // The same command in another directory is a different entry and stays.
    const other = try withLastFailure(a, &loaded, "zig build", "/x", 30);
    try std.testing.expectEqual(@as(usize, 3), other.len);
    try std.testing.expect(other[0].failed);

    // No failure (empty or blank slot) leaves the loaded list untouched.
    try std.testing.expectEqual(@as(usize, 2), (try withLastFailure(a, &loaded, "", "/w", 30)).len);
    try std.testing.expectEqual(@as(usize, 2), (try withLastFailure(a, &loaded, "   ", "/w", 30)).len);
}
