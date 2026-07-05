const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const root = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Shell scripts are embedded via named imports so @embedFile can reach them
    // from src/ without a `..` path escaping the module root.
    root.addAnonymousImport("init.bash", .{ .root_source_file = b.path("assets/init.bash") });
    root.addAnonymousImport("init.fish", .{ .root_source_file = b.path("assets/init.fish") });
    root.addAnonymousImport("init.zsh", .{ .root_source_file = b.path("assets/init.zsh") });

    const exe = b.addExecutable(.{ .name = "whetuu", .root_module = root });
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run whetuu");
    run_step.dependOn(&run_cmd.step);

    // Tests are inline in each module and pulled in through src/main.zig.
    const test_step = b.step("test", "Run tests");
    const exe_test = b.addTest(.{ .root_module = root });
    test_step.dependOn(&b.addRunArtifact(exe_test).step);

    const fmt_step = b.step("fmt", "Format all source files");
    fmt_step.dependOn(&b.addFmt(.{ .paths = &.{ "src", "build.zig" } }).step);

    const check_step = b.step("check", "Check if whetuu compiles");
    const check = b.addExecutable(.{ .name = "whetuu", .root_module = root });
    check_step.dependOn(&check.step);
}
