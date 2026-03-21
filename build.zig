const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const version = b.option([]const u8, "version", "Version string reported by `wt version`") orelse "0.1.0-dev";

    const options = b.addOptions();
    options.addOption([]const u8, "version", version);

    const root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    root_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "wt",
        .root_module = root_module,
    });

    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the wt CLI");
    run_step.dependOn(&run_cmd.step);

    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });
    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);

    const check_step = b.step("check", "Build the CLI and run unit tests");
    check_step.dependOn(b.getInstallStep());
    check_step.dependOn(&run_unit_tests.step);

    const release_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = .ReleaseSmall,
        .strip = true,
        .single_threaded = true,
        .unwind_tables = .none,
        .omit_frame_pointer = true,
        .error_tracing = false,
        .stack_protector = false,
        .stack_check = false,
        .valgrind = false,
    });
    release_module.addOptions("build_options", options);
    const release_exe = b.addExecutable(.{
        .name = "wt",
        .root_module = release_module,
    });
    const release_step = b.step("release", "Build release-optimized binary");
    release_step.dependOn(&b.addInstallArtifact(release_exe, .{}).step);

    const parity_cmd = b.addSystemCommand(&.{
        "/usr/bin/env",
        b.fmt("WT_ZIG_REPO={s}", .{b.pathFromRoot(".")}),
        b.fmt("ZIG_GLOBAL_CACHE_DIR={s}", .{b.pathFromRoot(".zig-global-cache")}),
        b.fmt("ZIG_LOCAL_CACHE_DIR={s}", .{b.pathFromRoot(".zig-cache")}),
        b.pathFromRoot("scripts/parity-harness.sh"),
    });
    parity_cmd.step.dependOn(b.getInstallStep());
    const parity_step = b.step("parity", "Run the Go-vs-Zig parity harness");
    parity_step.dependOn(&parity_cmd.step);
}
