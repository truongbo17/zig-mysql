const std = @import("std");
const mysql = @import("zig_mysql");

// POSIX process CPU-clock ticks (CLOCKS_PER_SEC = 1,000,000 on CI Linux).
// Diagnostic only, never a cross-platform CPU SLA.
extern "c" fn clock() c_long;

const operations_per_worker: usize = 200;
const worker_counts = [_]usize{ 1, 8, 32 };
const cap: usize = 16;
const statements = [_][]const u8{
    "SELECT ? + 1", "SELECT ? + 2", "SELECT ? + 3", "SELECT ? + 4",
    "SELECT ? + 5", "SELECT ? + 6", "SELECT ? + 7", "SELECT ? + 8",
};

fn config(cache_size: usize) !mysql.Config {
    return .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
        .username = "zigtest", .password = "zig_mysql_test", .database = "zigtest",
        .statement_cache_capacity = cache_size,
    };
}

const Worker = struct {
    io: std.Io,
    pool: *mysql.Pool,
    cache_enabled: bool,
    latencies_ns: []u64,
    hits: u64 = 0,
    misses: u64 = 0,
    evictions: u64 = 0,
    failure: ?anyerror = null,

    fn run(self: *@This()) std.Io.Cancelable!void {
        self.runChecked() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.failure = err;
        };
    }

    fn runChecked(self: *@This()) !void {
        const conn = try self.pool.acquireWithTimeout(self.io, .fromSeconds(10));
        defer self.pool.release(self.io, conn);
        const initial = conn.statementCacheStats();
        for (self.latencies_ns, 0..) |*elapsed, index| {
            const sql = statements[index % statements.len];
            const started = std.Io.Clock.awake.now(self.io);
            var result = if (self.cache_enabled)
                try conn.executeCached(self.io, sql, &.{.{ .int = 40 }})
            else blk: {
                var stmt = try conn.prepare(self.io, sql);
                defer conn.closeStatement(self.io, &stmt) catch { conn.broken = true; };
                break :blk try conn.execute(self.io, stmt, &.{.{ .int = 40 }});
            };
            defer result.deinit();
            const parsed = try std.fmt.parseInt(i64, result.value.rows.items[0].values[0].?, 10);
            if (parsed != 40 + @as(i64, @intCast(index % statements.len)) + 1)
                return error.InvalidResult;
            elapsed.* = @intCast(@max(1, started.untilNow(self.io, .awake).toNanoseconds()));
        }
        const current = conn.statementCacheStats();
        self.hits = current.hits - initial.hits;
        self.misses = current.misses - initial.misses;
        self.evictions = current.evictions - initial.evictions;
    }
};

fn statusValue(io: std.Io, sql: []const u8) !u64 {
    var conn = try mysql.Client.connect(std.heap.page_allocator, io, try config(0));
    defer conn.deinit(io);
    var rows = try conn.query(io, sql);
    defer rows.deinit();
    return std.fmt.parseInt(u64, rows.value.rows.items[0].values[1].?, 10);
}

fn percentile(sorted: []const u64, percent: usize) f64 {
    const idx = @min(sorted.len - 1, (sorted.len * percent + 99) / 100 - 1);
    return @as(f64, @floatFromInt(sorted[idx])) / 1_000_000.0;
}

fn scenario(allocator: std.mem.Allocator, io: std.Io, workers: usize, use_cache: bool) !void {
    var pool = try mysql.Pool.init(allocator, .{
        .connection = try config(if (use_cache) 16 else 0),
        .max_open = cap,
        .max_idle = cap,
        .validate_on_acquire = false,
    });
    defer pool.deinit(io);

    const total = workers * operations_per_worker;
    const samples = try allocator.alloc(u64, total);
    defer allocator.free(samples);
    const tasks = try allocator.alloc(Worker, workers);
    defer allocator.free(tasks);
    const before_prepares = try statusValue(io, "SHOW GLOBAL STATUS LIKE 'Com_stmt_prepare'");
    const cpu_before = clock();
    const start = std.Io.Clock.awake.now(io);
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (tasks, 0..) |*task, i| {
        task.* = .{
            .io = io,
            .pool = &pool,
            .cache_enabled = use_cache,
            .latencies_ns = samples[i * operations_per_worker ..][0..operations_per_worker],
        };
        try group.concurrent(io, Worker.run, .{task});
    }
    try group.await(io);
    const cpu_after = clock();
    const elapsed_ns: u64 = @intCast(@max(1, start.untilNow(io, .awake).toNanoseconds()));
    for (tasks) |task| if (task.failure) |err| return err;
    const prepares_after = try statusValue(io, "SHOW GLOBAL STATUS LIKE 'Com_stmt_prepare'");
    const remaining_prepared = try statusValue(io, "SHOW GLOBAL STATUS LIKE 'Prepared_stmt_count'");
    var hits: u64 = 0;
    var misses: u64 = 0;
    var evictions: u64 = 0;
    for (tasks) |task| {
        hits += task.hits;
        misses += task.misses;
        evictions += task.evictions;
    }
    if (use_cache and misses == 0) return error.ExpectedCacheMisses;
    if (use_cache and hits == 0) return error.ExpectedCacheHits;
    std.mem.sort(u64, samples, {}, std.sort.asc(u64));
    const rate = @as(f64, @floatFromInt(total)) * 1_000_000_000.0 /
        @as(f64, @floatFromInt(elapsed_ns));
    const cpu_ms: f64 = if (cpu_after >= cpu_before)
        @as(f64, @floatFromInt(cpu_after - cpu_before)) / 1000.0
    else
        -1.0;
    std.debug.print(
        "CACHE_BENCH cache={d} workers={d} requests={d} req_s={d:.1} " ++
        "p50_ms={d:.3} p95_ms={d:.3} p99_ms={d:.3} cpu_ms={d:.3} " ++
        "hits={d} misses={d} evictions={d} server_prepares_delta={d} server_prepared_remaining={d}\n",
        .{ @intFromBool(use_cache), workers, total, rate,
            percentile(samples, 50), percentile(samples, 95), percentile(samples, 99),
            cpu_ms, hits, misses, evictions,
            prepares_after -| before_prepares, remaining_prepared },
    );
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;
    for (worker_counts) |workers| {
        try scenario(allocator, io, workers, false);
        try scenario(allocator, io, workers, true);
    }
}
