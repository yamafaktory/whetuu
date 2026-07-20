const std = @import("std");

/// Targets published by `zig build release`. Shells limit this to unix: the
/// prompt only integrates with fish, bash and zsh.
const release_targets = [_][]const u8{
    "x86_64-linux-musl",
    "aarch64-linux-musl",
    "x86_64-macos",
    "aarch64-macos",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const strip = b.option(bool, "strip", "Strip debug info from the binary") orelse false;
    const version = b.option([]const u8, "version", "Version reported by `whetuu --version`") orelse "dev";

    // Release builds stamp the tag in; a plain `zig build` reports "dev".
    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const root = module(b, target, optimize, strip, options);

    const exe = b.addExecutable(.{ .name = "whetuu", .root_module = root });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    run_cmd.addPassthruArgs();

    const run_step = b.step("run", "Run whetuu");
    run_step.dependOn(&run_cmd.step);

    // Tests are inline in each module and pulled in through src/main.zig.
    const test_step = b.step("test", "Run tests");
    const exe_test = b.addTest(.{ .root_module = root });
    test_step.dependOn(&b.addRunArtifact(exe_test).step);

    const fmt_step = b.step("fmt", "Format all source files");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &.{ b.path("src"), b.path("build.zig") } }).step);

    const check_step = b.step("check", "Check if whetuu compiles");
    const check = b.addExecutable(.{ .name = "whetuu", .root_module = root });
    check_step.dependOn(&check.step);

    const release_step = b.step("release", "Cross-compile and package a tarball for every release target");
    for (release_targets) |triple| {
        const query = std.Target.Query.parse(.{ .arch_os_abi = triple }) catch @panic("invalid release target triple");
        const release_exe = b.addExecutable(.{
            .name = "whetuu",
            .root_module = module(b, b.resolveTargetQuery(query), .ReleaseFast, true, options),
        });

        const name = b.fmt("whetuu-{s}-{s}.tar.gz", .{ version, triple });
        const tar = b.addSystemCommand(&.{ "tar", "-czf" });
        const tarball = tar.addOutputFileArg(name);
        tar.addArg("-C");
        tar.addDirectoryArg(release_exe.getEmittedBinDirectory());
        tar.addArg("whetuu");

        const install = b.addInstallFileWithDir(tarball, .prefix, b.fmt("release/{s}", .{name}));
        release_step.dependOn(&install.step);
    }

    // Publishing only pushes a tag; the workflow builds and uploads from a
    // clean checkout, so what ships never depends on the local working tree.
    const publish_step = b.step("publish", "Tag the current commit and push it, triggering the release workflow");
    const publish = b.addSystemCommand(&.{"bash"});
    publish.addFileArg(b.path("tools/release.sh"));
    publish.addArg(version);
    publish.stdio = .inherit;
    publish.step.dependOn(test_step);
    publish.step.dependOn(release_step);
    publish_step.dependOn(&publish.step);
}

/// The root module, built once per target. Every target needs the same shell
/// scripts and build options, so they are wired up here rather than at each
/// call site.
fn module(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    strip: bool,
    options: *std.Build.Step.Options,
) *std.Build.Module {
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
    });
    // Shell scripts are embedded via named imports so @embedFile can reach them
    // from src/ without a `..` path escaping the module root.
    mod.addAnonymousImport("init.bash", .{ .root_source_file = b.path("assets/init.bash") });
    mod.addAnonymousImport("init.fish", .{ .root_source_file = b.path("assets/init.fish") });
    mod.addAnonymousImport("init.zsh", .{ .root_source_file = b.path("assets/init.zsh") });
    mod.addOptions("build_options", options);
    return mod;
}
