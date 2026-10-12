const std = @import("std");
const mysql = @import("zig_mysql");

const row_count: usize = 256;

fn rowValue(index: usize) [2]mysql.Param {
    return .{ .{ .int = @intCast(index + 1) }, .{ .text = "vietnam-batch-fixture" } };
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var conn = try mysql.Client.connect(init.gpa, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
        .username = "zigtest", .password = "zig_mysql_test", .database = "zigtest",
    });
    defer conn.deinit(io);
    var created = try conn.query(io,
        "CREATE TEMPORARY TABLE zig_batch_bench (id INT PRIMARY KEY, label VARCHAR(100))");
    created.deinit();
    var stmt = try conn.prepare(io, "INSERT INTO zig_batch_bench VALUES (?, ?)");
    defer conn.closeStatement(io, &stmt) catch {};

    var data: [row_count][2]mysql.Param = undefined;
    var rows: [row_count][]const mysql.Param = undefined;
    for (&data, 0..) |*row, i| {
        row.* = rowValue(i);
        rows[i] = row;
    }

    try conn.begin(io);
    const start_single = std.Io.Clock.awake.now(io);
    for (&data) |*row| {
        var result = try conn.execute(io, stmt, row);
        result.deinit();
    }
    const single_ns: u64 = @intCast(@max(1, start_single.untilNow(io, .awake).toNanoseconds()));
    try conn.rollback(io);

    try conn.begin(io);
    const start_batch = std.Io.Clock.awake.now(io);
    var progress: mysql.Batch.Progress = .{};
    try mysql.Batch.execute(&conn, io, stmt, &rows, &progress, .{});
    const batch_ns: u64 = @intCast(@max(1, start_batch.untilNow(io, .awake).toNanoseconds()));
    try conn.rollback(io);
    if (progress.completed != row_count or progress.affected_rows != row_count)
        return error.InvalidBenchmarkResult;

    const single_ops_s = @as(f64, @floatFromInt(row_count)) * 1e9 / @as(f64, @floatFromInt(single_ns));
    const batch_ops_s = @as(f64, @floatFromInt(row_count)) * 1e9 / @as(f64, @floatFromInt(batch_ns));
    std.debug.print(
        "D2_BATCH rows={d} single_ops_s={d:.2} batch_ops_s={d:.2} " ++
        "single_ms={d:.3} batch_ms={d:.3} relative={d:.3}\n",
        .{ row_count, single_ops_s, batch_ops_s,
            @as(f64, @floatFromInt(single_ns)) / 1e6,
            @as(f64, @floatFromInt(batch_ns)) / 1e6,
            batch_ops_s / single_ops_s },
    );
}
