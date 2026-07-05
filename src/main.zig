//! whetuu entry point. Two subcommands:
//!   whetuu init <fish|bash|zsh>   — print the shell integration script
//!   whetuu prompt [flags]         — render the prompt (called by the shell)

const std = @import("std");

const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const Io = std.Io;
const cli = @import("cli.zig");
const history = @import("history.zig");
const init_scripts = @import("init_scripts.zig");
const picker = @import("picker.zig");
const render = @import("render.zig");

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

/// Handles the `history` subcommand: `history add -- <command>` records a
/// command, while a bare `history` opens the interactive picker and prints the
/// chosen command to stdout for the shell to place on the command line.
fn runHistory(io: Io, arena: Allocator, environ: *std.process.Environ.Map, args: []const [:0]const u8) !void {
    const xdg = environ.get("XDG_DATA_HOME") orelse "";
    const home = environ.get("HOME") orelse "";
    const path = (try history.storePath(arena, xdg, home)) orelse return;

    if (args.len > 0 and std.mem.eql(u8, args[0], "add")) {
        const rest = args[1..];
        const words = if (rest.len > 0 and std.mem.eql(u8, rest[0], "--")) rest[1..] else rest;

        const parts = try arena.alloc([]const u8, words.len);
        for (words, parts) |word, *part| part.* = word;

        return history.add(io, arena, path, try std.mem.join(arena, " ", parts), unixNow(io));
    }

    const items = try history.load(io, arena, path);
    const chosen = picker.pick(arena, items, unixNow(io)) orelse return;

    var buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &buf);
    try fw.interface.writeAll(chosen);
    try fw.interface.writeByte('\n');
    try fw.interface.flush();
}

/// Builds the `Context` from flags and environment, then renders to stdout.
fn runPrompt(io: Io, arena: Allocator, environ: *std.process.Environ.Map, args: []const [:0]const u8) !void {
    const opts = try cli.parsePrompt(args);

    var cwd_buf: [max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io, &cwd_buf) catch 0;

    const ctx: Context = .{
        .cwd = cwd_buf[0..cwd_len],
        .duration_ms = opts.duration_ms,
        .exit_status = opts.exit_status,
        .home = environ.get("HOME") orelse "",
        .shell = opts.shell,
        .width = opts.width,
    };

    var out_buf: [4096]u8 = undefined;
    var fw = Io.File.stdout().writer(io, &out_buf);
    try render.render(io, arena, &ctx, &fw.interface);
    try fw.interface.flush();
}

/// Current wall-clock time as unix seconds, used to stamp and age history.
fn unixNow(io: Io) i64 {
    return Io.Clock.now(.real, io).toSeconds();
}

/// Prints a one-line usage summary to stderr.
fn usage(io: Io) !void {
    var buf: [256]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &buf);
    try fw.interface.writeAll("usage: whetuu <init <fish|bash|zsh> | prompt [--shell S] [--status N] [--duration-ms N] [--width N] | history [add -- <command>]>\n");
    try fw.interface.flush();
}

test {
    _ = @import("cli.zig");
    _ = @import("context.zig");
    _ = @import("history.zig");
    _ = @import("init_scripts.zig");
    _ = @import("picker.zig");
    _ = @import("module_character.zig");
    _ = @import("module_cmd_duration.zig");
    _ = @import("module_directory.zig");
    _ = @import("module_git.zig");
    _ = @import("module_language.zig");
    _ = @import("reltime.zig");
    _ = @import("render.zig");
    _ = @import("style.zig");
}
