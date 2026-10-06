const std = @import("std");
const mysql = @import("zig_mysql");

test "MySQL 8.4 or 9.x caching SHA2 over Unix socket" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .unix = try std.Io.net.UnixAddress.init("/var/run/mysqld/mysqld.sock") },
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
