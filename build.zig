const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const module = b.addModule("zig_mysql", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.link_libc = true;
    module.linkSystemLibrary("ssl", .{});
    module.linkSystemLibrary("crypto", .{});
    if (target.result.os.tag == .macos) {
        const prefix = b.option([]const u8, "openssl_prefix", "OpenSSL installation prefix") orelse "/opt/homebrew/opt/openssl@3";
        const lib_path = b.fmt("{s}/lib", .{prefix});
        module.addLibraryPath(.{ .cwd_relative = lib_path });
        module.addRPath(.{ .cwd_relative = lib_path });
    }
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

    const bench_module = b.createModule(.{
        .root_source_file = b.path("bench/pool.zig"),
        .target = target,
        .optimize = optimize,
    });
    bench_module.addImport("zig_mysql", module);
    const bench_exe = b.addExecutable(.{
        .name = "zig-mysql-pool-bench",
        .root_module = bench_module,
    });
    const run_bench = b.addRunArtifact(bench_exe);
    const bench_step = b.step("bench", "Benchmark pooled MySQL queries on localhost:33306");
    bench_step.dependOn(&run_bench.step);

    const tls_module = b.createModule(.{
        .root_source_file = b.path("integration/tls_local.zig"),
        .target = target,
        .optimize = optimize,
    });
    tls_module.addImport("zig_mysql", module);
    const tls_tests = b.addTest(.{ .root_module = tls_module });
    const run_tls = b.addRunArtifact(tls_tests);
    const tls_step = b.step("tls-integration", "Run verified TLS test against local MySQL on port 33307");
    tls_step.dependOn(&run_tls.step);
}
