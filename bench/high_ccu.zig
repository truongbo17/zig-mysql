const std = @import("std");
const mysql = @import("zig_mysql");

extern "c" fn clock() c_long; // process CPU clock, diagnostic
const worker_counts = [_]usize{ 1, 8, 32, 64, 128 };
const iterations: usize = 32;
const pool_limit: usize = 32;

const Worker = struct {
    io: std.Io,
    pool: *mysql.Pool,
    latencies_ns: []u64,
    failure: ?anyerror = null,
    fn task(self: *@This()) std.Io.Cancelable!void {
        self.checked() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.failure = err;
        };
    }
    fn checked(self: *@This()) !void {
        for (self.latencies_ns) |*duration| {
            const started = std.Io.Clock.awake.now(self.io);
            const conn = try self.pool.acquire(self.io);
            {
                defer self.pool.release(self.io, conn);
                var rows = try conn.queryWithTimeout(self.io, "SELECT 1", .fromSeconds(5));
                defer rows.deinit();
                if (!std.mem.eql(u8, rows.value.rows.items[0].values[0].?, "1"))
                    return error.InvalidBenchmarkResult;
            }
            duration.* = @intCast(@max(1, started.untilNow(self.io, .awake).toNanoseconds()));
        }
    }
};

fn percentile(sorted: []const u64, percentage: usize) f64 {
    const index = @min(sorted.len - 1, (sorted.len * percentage + 99) / 100 - 1);
    return @as(f64, @floatFromInt(sorted[index])) / 1_000_000.0;
}

fn config(tls: bool) !mysql.Config {
    return .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral(if (tls)
            "127.0.0.1:33307" else "127.0.0.1:33306") },
        .username = if (tls) "root" else "zigtest",
        .password = "zig_mysql_test",
        .database = "zigtest",
        .tls = if (tls) .{
            .host = "MySQL_Server_8.4.11_Auto_Generated_Server_Certificate",
            .ca_file = "/tmp/zig-mysql-test-ca.pem",
        } else null,
    };
}

fn scenario(allocator: std.mem.Allocator, io: std.Io, tls: bool, count: usize) !void {
    var pool = try mysql.Pool.init(allocator, .{
        .connection = try config(tls),
        .max_open = pool_limit,
        .max_idle = pool_limit,
        .health_check_timeout = null,
        .session_reset_timeout = null,
        .connect_attempt_timeout = .fromSeconds(5),
    });
    defer pool.deinit(io);
    const samples = try allocator.alloc(u64, count * iterations);
    defer allocator.free(samples);
    const tasks = try allocator.alloc(Worker, count);
    defer allocator.free(tasks);
    var group: std.Io.Group = .init;
    // await and cancel are alternative terminal operations in std.Io.Group.
    // Only cancel unfinished tasks when a startup/wait error occurs.
    var joined = false;
    defer if (!joined) group.cancel(io);
    const cpu_before = clock();
    const began = std.Io.Clock.awake.now(io);
    for (tasks, 0..) |*task, index| {
        task.* = .{ .io = io, .pool = &pool,
            .latencies_ns = samples[index * iterations ..][0..iterations] };
        try group.concurrent(io, Worker.task, .{task});
    }
    try group.await(io);
    joined = true;
    const cpu_after = clock();
    for (tasks) |task| if (task.failure) |err| return err;
    const elapsed: u64 = @intCast(@max(1, began.untilNow(io, .awake).toNanoseconds()));
    const stats = pool.stats(io);
    if (stats.in_use != 0 or stats.open > pool_limit) return error.BenchmarkPoolLeak;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const rate = @as(f64, @floatFromInt(samples.len)) * 1_000_000_000.0 /
        @as(f64, @floatFromInt(elapsed));
    const cpu_ms: f64 = if (cpu_after >= cpu_before)
        @as(f64, @floatFromInt(cpu_after - cpu_before)) / 1000.0 else -1.0;
    std.debug.print(
        "D4_CCU tls={d} workers={d} pool={d} requests={d} req_s={d:.1} " ++
        "p50_ms={d:.3} p95_ms={d:.3} p99_ms={d:.3} cpu_ms={d:.1} " ++
        "created={d} closed={d} wait={d} acquire_timeout={d}\n",
        .{ @intFromBool(tls), count, pool_limit, samples.len, rate,
            percentile(samples, 50), percentile(samples, 95),
            percentile(samples, 99), cpu_ms,
            stats.connections_created, stats.connections_closed,
            stats.waits, stats.acquire_timeouts },
    );
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, tls: bool) !void {
    for (worker_counts) |count| try scenario(allocator, io, tls, count);
}

pub fn main(init: std.process.Init) !void {
    // Pool instances are accessed by 128 concurrent workers. Use the
    // OS-backed thread-safe allocator, not a potentially unsynchronized GPA.
    try run(std.heap.page_allocator, init.io, false);
}
