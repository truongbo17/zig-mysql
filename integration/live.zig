const std = @import("std");
const mysql = @import("zig_mysql");

test "MySQL 8.0 text query and result rows" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306"),
        .username = "zigtest",
        .password = "zig_mysql_test",
        .database = "zigtest",
    });
    defer client.deinit(io);
    try client.ping(io);

    var create = try client.query(io, "CREATE TEMPORARY TABLE sample (id INT NOT NULL, label VARCHAR(40))");
    defer create.deinit();
    try std.testing.expectEqual(@as(u64, 0), create.value.ok.affected_rows);

    var insert = try client.query(io, "INSERT INTO sample VALUES (1, 'hello'), (2, NULL)");
    defer insert.deinit();
    try std.testing.expectEqual(@as(u64, 2), insert.value.ok.affected_rows);

    var select = try client.query(io, "SELECT id, label FROM sample ORDER BY id");
    defer select.deinit();
    const rows = select.value.rows;
    try std.testing.expectEqual(@as(usize, 2), rows.columns.len);
    try std.testing.expectEqualStrings("label", rows.columns[1].name);
    try std.testing.expectEqual(@as(usize, 2), rows.items.len);
    try std.testing.expectEqualStrings("hello", rows.items[0].values[1].?);
    try std.testing.expectEqual(@as(?[]const u8, null), rows.items[1].values[1]);
}
