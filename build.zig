const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zig_mysql", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const tests = b.addTest(.{ .root_module = module });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const live_module = b.createModule(.{
        .root_source_file = b.path("integration/live.zig"),
        .target = target,
        .optimize = optimize,
    });
    live_module.addImport("zig_mysql", module);
    const live_tests = b.addTest(.{ .root_module = live_module });
    const run_live = b.addRunArtifact(live_tests);
    const integration_step = b.step("integration", "Run tests against local MySQL on port 33306");
    integration_step.dependOn(&run_live.step);
}
