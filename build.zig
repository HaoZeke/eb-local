const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{ .abi = .musl, .cpu_model = .baseline } });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });
    const commit = b.option([]const u8, "commit", "Commit the binary is built from") orelse "unknown";
    // Debug info carries absolute build paths; a release binary leaves it
    // out so two builds of one commit are byte-identical.
    const strip = b.option(bool, "strip", "Leave out debug info (default: on for release builds)") orelse (optimize != .debug);

    // The test artifact may read its mount table from EB_LOCAL_TEST_MOUNTINFO;
    // a release build never can.
    const test_ops = b.option(bool, "test-ops", "Let tests supply the mount table (test artifacts only)") orelse false;
    if (test_ops and optimize != .debug) @panic("-Dtest-ops is for test builds only");

    const options = b.addOptions();
    options.addOption([]const u8, "commit", commit);
    options.addOption(bool, "test_ops", test_ops);

    const common = b.dependency("zig_common", .{ .target = target, .optimize = optimize });
    const mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
        .strip = strip,
        .imports = &.{
            .{ .name = "zig_common", .module = common.module("zig_common") },
            .{ .name = "build_options", .module = options.createModule() },
        },
    });
    const exe = b.addExecutable(.{ .name = "eb-local", .root_module = mod, .linkage = .static });
    b.installArtifact(exe);

    const unit = b.addTest(.{ .root_module = mod });
    b.step("unit", "Run the unit tests").dependOn(&b.addRunArtifact(unit).step);

    // The 1.x command-line suite, run against this binary.
    const suite = b.addSystemCommand(&.{ "bash", "-c", "EB_LOCAL_BIN=\"$0\" exec python3 -m unittest discover -s tests" });
    suite.addArtifactArg(exe);
    suite.expectExitCode(0);

    const test_step = b.step("test", "Run the unit tests and the command-line suite against the binary");
    test_step.dependOn(&b.addRunArtifact(unit).step);
    test_step.dependOn(&suite.step);
}
