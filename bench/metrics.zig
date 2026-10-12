const std = @import("std");
const mysql = @import("zig_mysql");

extern "c" fn clock() c_long;
const loops: usize = 500;

fn run(allocator: std.mem.Allocator, io: std.Io, enabled: bool) !void {
    var client = try mysql.Client.connect(allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
        .username = "zigtest", .password = "zig_mysql_test", .database = "zigtest",
    });
    defer client.deinit(io);
    var collector: mysql.CommandMetrics.Recorder = .{};
    if (enabled) client.setCommandMetrics(&collector);
    // Warm sockets and DB before the timed window.
    for (0..30) |_| {
        var warm = try client.query(io, "SELECT 1");
        warm.deinit();
    }
    const cpu_begin = clock();
    const started = std.Io.Clock.awake.now(io);
    for (0..loops) |_| {
        var result = try client.query(io, "SELECT 1");
        result.deinit();
    }
    const elapsed: u64 = @intCast(@max(1, started.untilNow(io, .awake).toNanoseconds()));
    const cpu_end = clock();
    const cpu_ms: f64 = if (cpu_end >= cpu_begin)
        @as(f64, @floatFromInt(cpu_end - cpu_begin)) / 1000.0 else -1.0;
    if (enabled and collector.operations(.query) != loops + 30)
        return error.IncorrectMetricCount;
    std.debug.print(
        "D1_METRICS enabled={d} iterations={d} avg_us={d:.2} total_ms={d:.2} " ++
        "cpu_ms={d:.2} recorded={d}\n",
        .{ @intFromBool(enabled), loops,
            @as(f64, @floatFromInt(elapsed)) / @as(f64, @floatFromInt(loops)) / 1000.0,
            @as(f64, @floatFromInt(elapsed)) / 1e6, cpu_ms, collector.operations(.query) },
    );
}

pub fn main(init: std.process.Init) !void {
    try run(init.gpa, init.io, false);
    try run(init.gpa, init.io, true);
}
