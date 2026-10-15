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
        // Handshake and authenticate 32 independent TLS sessions in parallel;
        // intentionally issue NO COM_QUERY to isolate connection lifecycle.
    }
};

fn oneRound(io: std.Io) !void {
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
    std.debug.print("TLS_HANDSHAKE_ONLY workers={d} handshakes={d} total_ms={d:.2}\\n",
        .{ workers_count, workers_count,
            @as(f64, @floatFromInt(elapsed_ns)) / 1e6 });
}

pub fn main(init: std.process.Init) !void {
    // 24 rounds * 32 concurrent verified TLS handshakes under Valgrind, long enough for
    // live RSS/fd polling; detects failure that requires repeated sessions.
    for (0..24) |_| try oneRound(init.io);
}
