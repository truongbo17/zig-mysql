const std = @import("std");
const mysql = @import("zig_mysql");

// A single Zig process and a single connection pool are held throughout the
// run. Re-running zig build stress-integration in a shell loop cannot detect
// persistent pool leaks because every invocation starts a fresh process.
extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;

const Worker = struct {
    io: std.Io,
    pool: *mysql.Pool,
    failure: ?anyerror = null,

    fn run(self: *@This()) std.Io.Cancelable!void {
        self.execute() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.failure = err;
        };
    }

    fn execute(self: *@This()) !void {
        for (0..80) |_| {
            const connection = try self.pool.acquireWithTimeout(self.io, .fromSeconds(10));
            defer self.pool.release(self.io, connection);
            var result = try connection.queryWithTimeout(self.io, "SELECT 1", .fromSeconds(5));
            defer result.deinit();
            if (!std.mem.eql(u8, result.value.rows.items[0].values[0].?, "1"))
                return error.CorruptedQueryResult;
            if (self.pool.stats(self.io).open > 8) return error.ConnectionCapExceeded;
        }
    }
};

test "one-process long-lived pool soak: slot accounting remains bounded" {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const seconds: u64 = if (getenv("SOAK_SECONDS")) |raw|
        try std.fmt.parseInt(u64, std.mem.span(raw), 10)
    else
        10;
    if (seconds == 0 or seconds > 86_400) return error.InvalidSoakDuration;

    // In a dedicated staging runner these env vars target a disposable,
    // isolated MySQL database. The fallback is the local CI test fixture.
    // getenv-owned environment string slices remain alive for this test.
    const address = if (getenv("SOAK_MYSQL_ADDRESS")) |value|
        std.mem.span(value)
    else
        "127.0.0.1:33306";
    const username = if (getenv("SOAK_MYSQL_USERNAME")) |value|
        std.mem.span(value)
    else
        "zigtest";
    const password = if (getenv("SOAK_MYSQL_PASSWORD")) |value|
        std.mem.span(value)
    else
        "zig_mysql_test";
    const database = if (getenv("SOAK_MYSQL_DATABASE")) |value|
        std.mem.span(value)
    else
        "zigtest";

    var pool = try mysql.Pool.init(std.heap.page_allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral(address) },
            .username = username,
            .password = password,
            .database = database,
        },
        .max_open = 8,
        .max_idle = 8,
        .health_check_timeout = .fromSeconds(3),
        .session_reset_timeout = .fromSeconds(3),
        .max_idle_time = .fromSeconds(60),
        .max_connection_age = .fromSeconds(600),
    });
    defer pool.deinit(io);

    const start = std.Io.Clock.awake.now(io);
    const target_ns: i128 = @as(i128, @intCast(seconds)) * 1_000_000_000;
    var rounds: usize = 0;
    while (rounds == 0 or start.untilNow(io, .awake).toNanoseconds() < target_ns) {
        var tasks: [16]Worker = undefined;
        var group: std.Io.Group = .init;
        defer group.cancel(io);
        for (&tasks) |*task| {
            task.* = .{ .io = io, .pool = &pool };
            try group.concurrent(io, Worker.run, .{task});
        }
        try group.await(io);
        for (tasks) |task| if (task.failure) |err| return err;
        rounds += 1;
        const stats = pool.stats(io);
        try std.testing.expect(stats.open <= 8);
        try std.testing.expect(stats.idle <= 8);
        try std.testing.expectEqual(@as(usize, 0), stats.in_use);
        try std.testing.expectEqual(stats.connections_created - stats.connections_closed, stats.open);
        if (rounds % 10 == 0) {
            std.debug.print("SOAK progress rounds={d}, requests={d}, open={d}, idle={d}, waits={d}, reset_failures={d}\n",
                .{ rounds, rounds * 1280, stats.open, stats.idle, stats.waits, stats.reset_failures });
        }
    }
    const stats = pool.stats(io);
    try std.testing.expectEqual(@as(usize, 0), stats.reset_failures);
    try std.testing.expectEqual(@as(usize, 0), stats.connect_failures);
    try std.testing.expectEqual(@as(usize, 0), stats.acquire_timeouts);
    std.debug.print("SOAK COMPLETE rounds={d}, requests={d}, seconds_requested={d}, open={d}, idle={d}, closed={d}\n",
        .{ rounds, rounds * 1280, seconds, stats.open, stats.idle, stats.connections_closed });
}
