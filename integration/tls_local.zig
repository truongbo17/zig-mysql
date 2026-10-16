const std = @import("std");
const mysql = @import("zig_mysql");
const e2 = @import("e2_large_prepared.zig");

test "verified TLS to MySQL 8.4" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33307") },
        .username = "root",
        .password = "zig_mysql_test",
        .database = "zigtest",
        .tls = .{ .host = "MySQL_Server_8.4.11_Auto_Generated_Server_Certificate", .ca_file = "/tmp/zig-mysql-test-ca.pem" },
    });
    defer client.deinit(io);
    try client.ping(io);
    var cipher = try client.query(io, "SHOW STATUS LIKE 'Ssl_cipher'");
    defer cipher.deinit();
    try std.testing.expect(cipher.value.rows.items[0].values[1].?.len > 0);
}

test "TLS rejects a server certificate with the wrong host" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    try std.testing.expectError(error.TlsHandshakeFailed, mysql.Client.connect(std.testing.allocator, threaded.io(), .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33307") },
        .username = "root",
        .password = "zig_mysql_test",
        .tls = .{ .host = "wrong.example", .ca_file = "/tmp/zig-mysql-test-ca.pem" },
    }));
}

test "nonblocking TLS deadline covers handshake, buffered SQL and pool recycle" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const config: mysql.Config = .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33307") },
        .username = "root",
        .password = "zig_mysql_test",
        .database = "zigtest",
        .tls = .{
            .host = "MySQL_Server_8.4.11_Auto_Generated_Server_Certificate",
            .ca_file = "/tmp/zig-mysql-test-ca.pem",
        },
    };

    var direct = try mysql.Client.connectWithTimeout(std.testing.allocator, io, config, .fromSeconds(5));
    try direct.pingWithTimeout(io, .fromSeconds(2));
    var good = try direct.queryWithTimeout(io, "SELECT 42", .fromSeconds(2));
    try std.testing.expectEqualStrings("42", good.value.rows.items[0].values[0].?);
    good.deinit();
    try std.testing.expectError(error.QueryTimeout, direct.queryWithTimeout(io, "SELECT SLEEP(2)", .fromMilliseconds(50)));
    try std.testing.expect(direct.broken);
    direct.deinit(io);

    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = config,
        .max_open = 2,
        .max_idle = 2,
        .health_check_timeout = .fromSeconds(2),
    });
    defer pool.deinit(io);
    const borrowed = try pool.acquireWithTimeout(io, .fromSeconds(5));
    try borrowed.pingWithTimeout(io, .fromSeconds(2));
    var stream = try borrowed.queryRowsWithTimeout(io, "SELECT 1 UNION ALL SELECT 2", .fromSeconds(2));
    try std.testing.expectEqualStrings("1", (try stream.nextWithTimeout(io, .fromSeconds(2))).?.values[0].?);
    try std.testing.expectEqualStrings("2", (try stream.nextWithTimeout(io, .fromSeconds(2))).?.values[0].?);
    try std.testing.expect((try stream.nextWithTimeout(io, .fromSeconds(2))) == null);
    stream.deinit(io);
    pool.release(io, borrowed);
    const reused = try pool.acquireWithTimeout(io, .fromSeconds(5));
    try reused.pingWithTimeout(io, .fromSeconds(2));
    pool.release(io, reused);
    try std.testing.expectEqual(@as(usize, 0), pool.stats(io).in_use);
}

test "TLS failed certificate verification never poisons a later valid session on same thread" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const wrong: mysql.Config = .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33307") },
        .username = "root", .password = "zig_mysql_test", .database = "zigtest",
        .tls = .{ .host = "wrong.example", .ca_file = "/tmp/zig-mysql-test-ca.pem" },
    };
    try std.testing.expectError(error.TlsHandshakeFailed,
        mysql.Client.connect(std.testing.allocator, io, wrong));

    var correct = wrong;
    correct.tls = .{
        .host = "MySQL_Server_8.4.11_Auto_Generated_Server_Certificate",
        .ca_file = "/tmp/zig-mysql-test-ca.pem",
    };
    var conn = try mysql.Client.connect(std.testing.allocator, io, correct);
    defer conn.deinit(io);
    try conn.pingWithTimeout(io, .fromSeconds(2));
    var result = try conn.queryWithTimeout(io, "SELECT 1", .fromSeconds(2));
    defer result.deinit();
    try std.testing.expectEqualStrings("1", result.value.rows.items[0].values[0].?);
}

test "E2 cross-server >16MiB prepared BLOB framing" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conn = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33307") },
        .username = "root", .password = "zig_mysql_test", .database = "zigtest", .tls = .{ .host = "MySQL_Server_8.4.11_Auto_Generated_Server_Certificate", .ca_file = "/tmp/zig-mysql-test-ca.pem" },
    });
    defer conn.deinit(io);
    try e2.verify(&conn, io);
}
