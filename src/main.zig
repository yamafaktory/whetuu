//! whetuu entry point. Two subcommands:
//!   whetuu init <fish|bash|zsh>   — print the shell integration script
//!   whetuu prompt [flags]         — render the prompt (called by the shell)

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Env = @import("Env.zig");
const cli = @import("cli.zig");
const history = @import("history.zig");
const init_scripts = @import("init_scripts.zig");
const picker = @import("picker.zig");
const render = @import("render.zig");
const style = @import("style.zig");

/// Upper bound on a current-directory path. Beyond this the directory is simply
/// reported empty rather than overrunning the buffer.
const max_path_bytes = 4096;

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    if (args.len < 2) return usage(io);

    const sub = args[1];
    if (std.mem.eql(u8, sub, "init")) {
        if (args.len < 3) return usage(io);
        return init_scripts.write(io, args[2]);
    }

    if (std.mem.eql(u8, sub, "prompt")) {
        return runPrompt(io, arena, init.environ_map, args[2..]);
    }

    if (std.mem.eql(u8, sub, "history")) {
        return runHistory(io, arena, init.environ_map, args[2..]);
    }

    return usage(io);
}

/// Builds the `Env` from flags and environment, then renders to stdout.
fn runPrompt(io: Io, arena: Allocator, environ: *std.process.Environ.Map, args: []const [:0]const u8) !void {
    const opts = try cli.parsePrompt(args);

    var cwd_buf: [max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;

    const env: Env = .{
        .shell = opts.shell,
        .cwd = cwd_buf[0..cwd_len],
        .home = environ.get("HOME") orelse "",
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
/// that ran successfully are stored), while `history [--query <text>]` opens
/// the interactive picker — seeded with `text`, the shell's current command
/// line — and prints the chosen command to stdout for the shell to place on
/// the command line.
fn runHistory(io: Io, arena: Allocator, environ: *std.process.Environ.Map, args: []const [:0]const u8) !void {
    const xdg = environ.get("XDG_DATA_HOME") orelse "";
    const home = environ.get("HOME") orelse "";
    const path = (try history.storePath(arena, xdg, home)) orelse return;

    if (args.len > 0 and std.mem.eql(u8, args[0], "add")) {
        const opts = try cli.parseHistoryAdd(args[1..]);
        if (opts.exit_status != 0) return;

        const parts = try arena.alloc([]const u8, opts.words.len);
        for (opts.words, parts) |word, *part| part.* = word;
        return history.add(io, arena, path, try std.mem.join(arena, " ", parts), unixNow(io));
    }

    const initial = if (args.len >= 2 and std.mem.eql(u8, args[0], "--query")) args[1] else "";
    const items = try history.load(io, arena, path);
    const chosen = picker.pick(io, arena, items, initial) orelse return;

    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(chosen);
    try fw.interface.writeByte('\n');
    try fw.interface.flush();
}

/// Current wall-clock time as unix seconds, used to stamp and age history.
fn unixNow(io: Io) i64 {
    return Io.Clock.now(.real, io).toSeconds();
}

/// Prints the vertical, colorized help to stderr: the star emblem and command
/// names in the whetuu brand purple, descriptions dimmed, one entry per line.
/// The wordmark is deliberately absent — the prompt right above the output
/// already shows it — and so are the flags of `prompt` and `history add`,
/// which only the shell init scripts ever pass.
fn usage(io: Io) !void {
    const bold = style.sgr.bold;
    const dim = style.sgr.dim;
    const purple = style.sgr.fg_purple;
    const reset = style.sgr.reset;

    const text =
        purple ++ style.icon.star ++ reset ++ " " ++
        dim ++ "opinionated, zero-config, async cross-shell prompt" ++ reset ++ "\n" ++
        "\n" ++
        bold ++ "Commands" ++ reset ++ "\n" ++
        "  " ++ purple ++ "init" ++ reset ++ " <fish|bash|zsh>   " ++ dim ++ "Print the shell integration script" ++ reset ++ "\n" ++
        "  " ++ purple ++ "prompt" ++ reset ++ "                 " ++ dim ++ "Render the prompt (called by the shell)" ++ reset ++ "\n" ++
        "  " ++ purple ++ "history" ++ reset ++ "                " ++ dim ++ "Open the interactive history picker" ++ reset ++ "\n" ++
        "  " ++ purple ++ "history add" ++ reset ++ "            " ++ dim ++ "Record a finished command (status 0 only)" ++ reset ++ "\n";

    var buf: [256]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &buf);
    try fw.interface.writeAll(text);
    try fw.interface.flush();
}

test {
    _ = @import("Env.zig");
    _ = @import("cli.zig");
    _ = @import("history.zig");
    _ = @import("init_scripts.zig");
    _ = @import("picker.zig");
    _ = @import("module_character.zig");
    _ = @import("module_cmd_duration.zig");
    _ = @import("module_directory.zig");
    _ = @import("module_git.zig");
    _ = @import("module_language.zig");
    _ = @import("render.zig");
    _ = @import("style.zig");
    _ = @import("time_ago.zig");
}
