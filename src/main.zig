//! whetuu entry point. Two subcommands:
//!   whetuu init <fish|bash|zsh>   — print the shell integration script
//!   whetuu prompt [flags]         — render the prompt (called by the shell)

const std = @import("std");

const Allocator = std.mem.Allocator;
const Context = @import("context.zig").Context;
const Io = std.Io;
const cli = @import("cli.zig");
const init_scripts = @import("init_scripts.zig");
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

    return usage(io);
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

/// Prints a one-line usage summary to stderr.
fn usage(io: Io) !void {
    var buf: [256]u8 = undefined;
    var fw = Io.File.stderr().writer(io, &buf);
    try fw.interface.writeAll("usage: whetuu <init <fish|bash|zsh> | prompt [--shell S] [--status N] [--duration-ms N] [--width N]>\n");
    try fw.interface.flush();
}

test {
    _ = @import("cli.zig");
    _ = @import("context.zig");
    _ = @import("init_scripts.zig");
    _ = @import("module_character.zig");
    _ = @import("module_cmd_duration.zig");
    _ = @import("module_directory.zig");
    _ = @import("module_git.zig");
    _ = @import("module_language.zig");
    _ = @import("render.zig");
    _ = @import("style.zig");
}
