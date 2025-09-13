const std = @import("std");

pub fn build(b: *std.Build) void {
    const phasor_channel_module = b.addModule("phasor-channel", .{
        .root_source_file = b.path("src/root.zig"),
        .target = b.standardTargetOptions(.{}),
        .optimize = b.standardOptimizeOption(.{}),
    });

    const phasor_channel_tests = b.addTest(.{
        .root_module = phasor_channel_module,
    });
    const run_phasor_channel_tests = b.addRunArtifact(phasor_channel_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_phasor_channel_tests.step);
}
