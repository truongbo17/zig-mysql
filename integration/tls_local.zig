const std = @import("std");
const mysql = @import("zig_mysql");

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
