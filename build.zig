const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const phasor_channel_mod = b.addModule("phasor-channel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    const phasor_channel_tests_mod = b.addModule("phasor_channel_tests", .{
        .root_source_file = b.path("tests/tests.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "phasor-channel", .module = phasor_channel_mod },
        },
    });

    const phasor_channel_tests = b.addTest(.{
        .root_module = phasor_channel_tests_mod,
    });
    const run_phasor_channel_tests = b.addRunArtifact(phasor_channel_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_phasor_channel_tests.step);
}
