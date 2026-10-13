const std = @import("std");
const mysql = @import("zig_mysql");

const workers_count = 32;
const iterations = 128;

const Worker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    failure: ?anyerror = null,

    fn work(self: *@This()) std.Io.Cancelable!void {
        self.execute() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.failure = err;
        };
    }
    fn execute(self: *@This()) !void {
        var conn = try mysql.Client.connect(self.allocator, self.io, .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33307") },
            .username = "root", .password = "zig_mysql_test", .database = "zigtest",
            .tls = .{
                .host = "MySQL_Server_8.4.11_Auto_Generated_Server_Certificate",
                .ca_file = "/tmp/zig-mysql-test-ca.pem",
            },
        });
        defer conn.deinit(self.io);
        for (0..iterations) |_| {
            var result = try conn.queryWithTimeout(self.io, "SELECT 1", .fromSeconds(5));
            defer result.deinit();
            if (!std.mem.eql(u8, result.value.rows.items[0].values[0].?, "1"))
                return error.BadResult;
        }
    }
};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var workers: [workers_count]Worker = undefined;
    var group: std.Io.Group = .init;
    var joined = false;
    defer if (!joined) group.cancel(io);
    const started = std.Io.Clock.awake.now(io);
    for (&workers) |*w| {
        w.* = .{ .io = io, .allocator = std.heap.page_allocator };
        try group.concurrent(io, Worker.work, .{w});
    }
    try group.await(io);
    joined = true;
    for (&workers) |w| if (w.failure) |err| return err;
    const elapsed_ns: u64 = @intCast(@max(1, started.untilNow(io, .awake).toNanoseconds()));
    std.debug.print("TLS_DIRECT_CLIENTS workers={d} operations={d} total_ms={d:.2}\\n",
        .{ workers_count, workers_count * iterations,
            @as(f64, @floatFromInt(elapsed_ns)) / 1e6 });
}
