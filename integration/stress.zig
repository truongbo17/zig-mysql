const std = @import("std");
const mysql = @import("zig_mysql");

const config: mysql.Config = .{
    .address = .{ .ip = std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") catch unreachable },
    .username = "zigtest",
    .password = "zig_mysql_test",
    .database = "zigtest",
};

const Worker = struct {
    io: std.Io,
    pool: *mysql.Pool,
    failure: ?anyerror = null,

    fn run(self: *@This()) std.Io.Cancelable!void {
        self.work() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.failure = err;
        };
    }

    fn work(self: *@This()) !void {
        for (0..100) |_| {
            const connection = try self.pool.acquireWithTimeout(self.io, .fromSeconds(10));
            defer self.pool.release(self.io, connection);
            var result = try connection.queryWithTimeout(self.io, "SELECT 1", .fromSeconds(5));
            defer result.deinit();
            if (!std.mem.eql(u8, result.value.rows.items[0].values[0].?, "1"))
                return error.BadQueryResult;
            if (self.pool.stats(self.io).open > 8) return error.ConnectionLimitExceeded;
        }
    }
};

test "concurrent acquisitions and fault injection respect hard pool limit" {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.heap.page_allocator, .{
        .connection = config,
        .max_open = 8,
        .max_idle = 8,
        .health_check_timeout = .fromSeconds(3),
        .max_idle_time = .fromSeconds(60),
        .max_connection_age = .fromSeconds(120),
    });
    defer pool.deinit(io);

    // A bounded concurrent workload with more borrowers than connections:
    // 32 * 100 operations, every operation also resets session on return.
    var workers: [32]Worker = undefined;
    var group: std.Io.Group = .init;
    defer group.cancel(io);
    for (&workers) |*worker| {
        worker.* = .{ .io = io, .pool = &pool };
        try group.concurrent(io, Worker.run, .{worker});
    }
    try group.await(io);
    for (workers) |worker| if (worker.failure) |err| return err;

    var stats = pool.stats(io);
    try std.testing.expect(stats.open <= 8);
    try std.testing.expect(stats.idle <= 8);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);

    // Close idle sessions from another connection. Each checkout must detect
    // the killed socket and recover without leaking a slot or stale result.
    var killer = try mysql.Client.connect(std.heap.page_allocator, io, config);
    defer killer.deinit(io);
    for (0..5) |_| {
        const connection = try pool.acquire(io);
        var id_result = try connection.query(io, "SELECT CONNECTION_ID()");
        const id = try std.fmt.parseInt(u64, id_result.value.rows.items[0].values[0].?, 10);
        id_result.deinit();
        pool.release(io, connection);

        const sql = try std.fmt.allocPrint(std.heap.page_allocator, "KILL CONNECTION {d}", .{id});
        defer std.heap.page_allocator.free(sql);
        var killed = try killer.query(io, sql);
        killed.deinit();

        const replacement = try pool.acquireWithTimeout(io, .fromSeconds(5));
        try replacement.ping(io);
        pool.release(io, replacement);
    }
    stats = pool.stats(io);
    try std.testing.expect(stats.open <= 8);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);
    try std.testing.expect(stats.health_check_failures >= 5);
}
