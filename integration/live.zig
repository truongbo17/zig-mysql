const std = @import("std");
const mysql = @import("zig_mysql");

test "MySQL 8.0 text query and result rows" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var client = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
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

    var insert_stmt = try client.prepare(io, "INSERT INTO sample VALUES (?, ?)");
    defer client.closeStatement(io, &insert_stmt) catch {};
    try std.testing.expectEqual(@as(u16, 2), insert_stmt.parameter_count);
    var bound_insert = try client.execute(io, insert_stmt, &.{ .{ .int = 3 }, .{ .text = "prepared" } });
    defer bound_insert.deinit();
    try std.testing.expectEqual(@as(u64, 1), bound_insert.value.ok.affected_rows);

    var select_stmt = try client.prepare(io, "SELECT id, label FROM sample WHERE id = ?");
    defer client.closeStatement(io, &select_stmt) catch {};
    try std.testing.expectError(error.ParameterCountMismatch, client.execute(io, select_stmt, &.{}));
    var bound_select = try client.execute(io, select_stmt, &.{.{ .int = 3 }});
    defer bound_select.deinit();
    try std.testing.expectEqual(@as(usize, 1), bound_select.value.rows.items.len);
    try std.testing.expectEqualStrings("3", bound_select.value.rows.items[0].values[0].?);
    try std.testing.expectEqualStrings("prepared", bound_select.value.rows.items[0].values[1].?);

    try client.begin(io);
    var transient = try client.execute(io, insert_stmt, &.{ .{ .int = 4 }, .{ .text = "rollback" } });
    transient.deinit();
    try client.rollback(io);
    var count = try client.query(io, "SELECT COUNT(*) FROM sample WHERE id = 4");
    defer count.deinit();
    try std.testing.expectEqualStrings("0", count.value.rows.items[0].values[0].?);

    try std.testing.expectError(error.ServerError, client.query(io, "SELECT * FROM table_that_does_not_exist"));
    try std.testing.expectEqual(@as(u16, 1146), client.last_server_error.?.code);
}
