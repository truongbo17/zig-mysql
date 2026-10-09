const std = @import("std");
const mysql = @import("zig_mysql");

/// Run against the disposable MySQL 8.0 server on 127.0.0.1:33306.
/// Each operation includes acquire, COM_PING when reusing an idle connection,
/// SELECT 1, COM_RESET_CONNECTION, and COM_INIT_DB on release.
const operations_per_worker: usize = 50;
const worker_counts = [_]usize{ 1, 8, 32 };
const pool_cap: usize = 16;

const Worker = struct {
    io: std.Io,
    pool: *mysql.Pool,
    timings_ns: []u64,
    failure: ?anyerror = null,

    // Io.Group.concurrent takes a Cancelable!void task. Preserve ordinary
    // database errors separately and report them after all workers join.
    fn run(self: *@This()) std.Io.Cancelable!void {
        self.runChecked() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.failure = err;
        };
    }

    fn runChecked(self: *@This()) !void {
        for (self.timings_ns) |*duration| {
            const start = std.Io.Clock.awake.now(self.io);
            {
                const connection = try self.pool.acquire(self.io);
                defer self.pool.release(self.io, connection);
                var result = try connection.query(self.io, "SELECT 1");
                defer result.deinit();
                const value = result.value.rows.items[0].values[0].?;
                if (!std.mem.eql(u8, value, "1")) return error.UnexpectedResult;
            }
            duration.* = @intCast(@max(0, start.untilNow(self.io, .awake).toNanoseconds()));
        }
    }
};

fn percentile(sorted: []const u64, percentage: usize) f64 {
    const idx = @min(sorted.len - 1, (sorted.len * percentage + 99) / 100 - 1);
    return @as(f64, @floatFromInt(sorted[idx])) / 1_000_000.0;
}

fn scenario(allocator: std.mem.Allocator, io: std.Io, workers: usize, validate: bool) !void {
    var pool = try mysql.Pool.init(allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
            .username = "zigtest",
            .password = "zig_mysql_test",
            .database = "zigtest",
        },
        .max_open = pool_cap,
        .max_idle = pool_cap,
        .validate_on_acquire = validate,
        .health_check_timeout = .fromSeconds(2),
    });
    defer pool.deinit(io);

    std.debug.print("starting scenario workers={d}, idle_validation={any}...\\n", .{ workers, validate });
    const total = workers * operations_per_worker;
    const latencies = try allocator.alloc(u64, total);
    defer allocator.free(latencies);
    const tasks = try allocator.alloc(Worker, workers);
    defer allocator.free(tasks);
    var group: std.Io.Group = .init;
    defer group.cancel(io);

    const start = std.Io.Clock.awake.now(io);
    for (tasks, 0..) |*task, i| {
        task.* = .{
            .io = io,
            .pool = &pool,
            .timings_ns = latencies[i * operations_per_worker ..][0..operations_per_worker],
        };
        try group.concurrent(io, Worker.run, .{task});
    }
    try group.await(io);
    for (tasks) |task| {
        if (task.failure) |err| return err;
    }
    const elapsed_ns: u64 = @intCast(@max(1, start.untilNow(io, .awake).toNanoseconds()));
    std.mem.sort(u64, latencies, {}, std.sort.asc(u64));
    const throughput = @as(f64, @floatFromInt(total)) * 1_000_000_000.0 /
        @as(f64, @floatFromInt(elapsed_ns));
    std.debug.print("{d:>7} {d:>8} {d:>6} {d:>9.1} {d:>9.2} {d:>9.2} {d:>9.2}\n", .{
        workers,
        total,
        @intFromBool(validate),
        throughput,
        percentile(latencies, 50),
        percentile(latencies, 95),
        percentile(latencies, 99),
    });
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    std.debug.print(
        "MySQL pool benchmark (max_open={d}, requests/worker={d})\n" ++
            "workers requests health   req/s    p50(ms)   p95(ms)   p99(ms)\n",
        .{ pool_cap, operations_per_worker },
    );
    for (worker_counts) |workers| {
        try scenario(allocator, io, workers, true);
        try scenario(allocator, io, workers, false);
    }
}
