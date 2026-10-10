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
    run_tests.has_side_effects = true; // Re-run tests against each live server / soak iteration.
    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_tests.step);

    const timeout_module = b.createModule(.{
        .root_source_file = b.path("integration/timeout_local.zig"),
        .target = target,
        .optimize = optimize,
    });
    timeout_module.addImport("zig_mysql", module);
    const timeout_tests = b.addTest(.{ .root_module = timeout_module });
    const run_timeout = b.addRunArtifact(timeout_tests);
    run_timeout.has_side_effects = true; // Re-run tests against each live server / soak iteration.
    const timeout_step = b.step("timeout-integration", "Verify TCP and TLS stalls expire safely");
    timeout_step.dependOn(&run_timeout.step);

    const live_module = b.createModule(.{
        .root_source_file = b.path("integration/live.zig"),
        .target = target,
        .optimize = optimize,
    });
    live_module.addImport("zig_mysql", module);
    const live_tests = b.addTest(.{ .root_module = live_module });
    const run_live = b.addRunArtifact(live_tests);
    run_live.has_side_effects = true; // Re-run tests against each live server / soak iteration.
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
    run_bench.has_side_effects = true; // Re-run tests against each live server / soak iteration.
    const bench_step = b.step("bench", "Benchmark pooled MySQL queries on localhost:33306");
    bench_step.dependOn(&run_bench.step);

    const soak_module = b.createModule(.{
        .root_source_file = b.path("integration/soak_local.zig"),
        .target = target,
        .optimize = optimize,
    });
    soak_module.addImport("zig_mysql", module);
    const soak_tests = b.addTest(.{ .root_module = soak_module });
    const run_soak = b.addRunArtifact(soak_tests);
    run_soak.has_side_effects = true; // Long-lived pool test must never be cached.
    const soak_step = b.step("soak-integration", "Run single-process sustained pool soak (SOAK_SECONDS)");
    soak_step.dependOn(&run_soak.step);

    const stress_module = b.createModule(.{
        .root_source_file = b.path("integration/stress.zig"),
        .target = target,
        .optimize = optimize,
    });
    stress_module.addImport("zig_mysql", module);
    const stress_tests = b.addTest(.{ .root_module = stress_module });
    const run_stress = b.addRunArtifact(stress_tests);
    run_stress.has_side_effects = true; // Re-run tests against each live server / soak iteration.
    const stress_step = b.step("stress-integration", "Run concurrent MySQL pool stress and killed-socket recovery tests");
    stress_step.dependOn(&run_stress.step);

    const mariadb_module = b.createModule(.{
        .root_source_file = b.path("integration/mariadb.zig"),
        .target = target,
        .optimize = optimize,
    });
    mariadb_module.addImport("zig_mysql", module);
    const mariadb_tests = b.addTest(.{ .root_module = mariadb_module });
    const run_mariadb = b.addRunArtifact(mariadb_tests);
    run_mariadb.has_side_effects = true; // Re-run tests against each live server / soak iteration.
    const mariadb_step = b.step("mariadb-integration", "Run live MariaDB integration against localhost:33308");
    mariadb_step.dependOn(&run_mariadb.step);

    const tls_module = b.createModule(.{
        .root_source_file = b.path("integration/tls_local.zig"),
        .target = target,
        .optimize = optimize,
    });
    tls_module.addImport("zig_mysql", module);
    const tls_tests = b.addTest(.{ .root_module = tls_module });
    const run_tls = b.addRunArtifact(tls_tests);
    run_tls.has_side_effects = true; // Re-run tests against each live server / soak iteration.
    const tls_step = b.step("tls-integration", "Run verified TLS test against local MySQL on port 33307");
    tls_step.dependOn(&run_tls.step);
}
