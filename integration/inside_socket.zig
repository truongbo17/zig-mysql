const std = @import("std");
const mysql = @import("zig_mysql");
const e1 = @import("e1_charset.zig");
const e2 = @import("e2_large_prepared.zig");

test "MySQL 8.4 or 9.x caching SHA2 over Unix socket" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .unix = try std.Io.net.UnixAddress.init("/tmp/zig-mysql-test-socket/mysqld.sock") },
        .username = "root",
        .password = "zig_mysql_test",
        .database = "zigtest",
    });
    defer client.deinit(io);
    try client.ping(io);
    var result = try client.query(io, "SELECT VERSION() AS version");
    defer result.deinit();
    const version = result.value.rows.items[0].values[0].?;
    try std.testing.expect(std.mem.startsWith(u8, version, "8.4.") or std.mem.startsWith(u8, version, "9."));

    var statement = try client.prepare(io, "SELECT ? AS answer");
    defer client.closeStatement(io, &statement) catch {};
    var bound = try client.execute(io, statement, &.{.{ .int = 42 }});
    defer bound.deinit();
    try std.testing.expectEqualStrings("42", bound.value.rows.items[0].values[0].?);
}

test "E2 cross-server >16MiB prepared BLOB framing" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conn = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .unix = try std.Io.net.UnixAddress.init("/tmp/zig-mysql-test-socket/mysqld.sock") },
        .username = "root", .password = "zig_mysql_test", .database = "zigtest",
    });
    defer conn.deinit(io);
    try e2.verify(&conn, io);
}

test "E1 utf8mb4 Unicode collation, SQL modes and prepared Vietnamese roundtrip" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conn = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .unix = try std.Io.net.UnixAddress.init("/tmp/zig-mysql-test-socket/mysqld.sock") },
        .username = "root",
        .password = "zig_mysql_test",
        .database = "zigtest",
        .collation = .unicode_ci,
    });
    defer conn.deinit(io);
    try e1.verify(&conn, io);
}
