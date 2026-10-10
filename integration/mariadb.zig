const std = @import("std");
const mysql = @import("zig_mysql");

test "MariaDB native auth, prepared parameters, transactions and pooled reset" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const config: mysql.Config = .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33308") },
        .username = "zigtest",
        .password = "zig_mysql_test",
        .database = "zigtest",
    };
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = config,
        .max_open = 2,
        .max_idle = 2,
        .max_connection_age = .fromSeconds(60),
    });
    defer pool.deinit(io);

    const conn = try pool.acquireWithTimeout(io, .fromSeconds(5));
    try conn.ping(io);
    var version = try conn.query(io, "SELECT VERSION()");
    try std.testing.expect(version.value.rows.items[0].values[0].?.len > 0);
    version.deinit();

    var create = try conn.query(io, "CREATE TEMPORARY TABLE zig_mariadb_test (id INT PRIMARY KEY, title VARCHAR(100) NULL)");
    create.deinit();
    var stmt = try conn.prepare(io, "INSERT INTO zig_mariadb_test VALUES (?, ?)");
    var inserted = try conn.execute(io, stmt, &.{ .{ .int = 7 }, .{ .text = "MariaDB prepared" } });
    try std.testing.expectEqual(@as(u64, 1), inserted.value.ok.affected_rows);
    inserted.deinit();
    try conn.closeStatement(io, &stmt);

    var select = try conn.query(io, "SELECT title FROM zig_mariadb_test WHERE id=7");
    try std.testing.expectEqualStrings("MariaDB prepared", select.value.rows.items[0].values[0].?);
    select.deinit();
    try conn.begin(io);
    var tx_insert = try conn.query(io, "INSERT INTO zig_mariadb_test VALUES (8, NULL)");
    tx_insert.deinit();
    try conn.rollback(io);
    var count = try conn.query(io, "SELECT COUNT(*) FROM zig_mariadb_test");
    try std.testing.expectEqualStrings("1", count.value.rows.items[0].values[0].?);
    count.deinit();
    pool.release(io, conn);

    const fresh = try pool.acquireWithTimeout(io, .fromSeconds(5));
    try std.testing.expectError(error.ServerError, fresh.query(io, "SELECT * FROM zig_mariadb_test"));
    try std.testing.expectEqual(@as(u16, 1146), fresh.last_server_error.?.code);
    try fresh.ping(io);
    pool.release(io, fresh);
}

test "MariaDB lossless DECIMAL binding and binary/text roundtrip" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conn = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33308") },
        .username = "zigtest",
        .password = "zig_mysql_test",
        .database = "zigtest",
    });
    defer conn.deinit(io);

    var create = try conn.query(io,
        "CREATE TEMPORARY TABLE zig_decimal_roundtrip (id INT PRIMARY KEY, amount DECIMAL(65,30))");
    create.deinit();

    var insert = try conn.prepare(io, "INSERT INTO zig_decimal_roundtrip VALUES (?, ?)");
    defer conn.closeStatement(io, &insert) catch {};
    try std.testing.expectError(error.InvalidDecimal, conn.execute(io, insert,
        &.{ .{ .int = 1 }, .{ .decimal = "12e3" } }));
    // Validation failure is local and must not poison the existing session.
    try conn.ping(io);

    const value = "12345678901234567890123456789012345.123456789012345678901234567890";
    const literal = try mysql.Decimal.parse(value);
    try std.testing.expectEqual(@as(u8, 65), literal.precision);
    try std.testing.expectEqual(@as(u8, 30), literal.scale);
    var write = try conn.execute(io, insert,
        &.{ .{ .int = 1 }, .{ .decimal = literal.bytes } });
    try std.testing.expectEqual(@as(u64, 1), write.value.ok.affected_rows);
    write.deinit();

    var text = try conn.query(io, "SELECT amount FROM zig_decimal_roundtrip WHERE id=1");
    try std.testing.expectEqual(@as(u8, 246), text.value.rows.columns[0].type_code);
    const read = try mysql.Decimal.parse(text.value.rows.items[0].values[0].?);
    try std.testing.expectEqualStrings(value, read.bytes);
    text.deinit();

    var select = try conn.prepare(io, "SELECT amount FROM zig_decimal_roundtrip WHERE id=?");
    defer conn.closeStatement(io, &select) catch {};
    var binary = try conn.execute(io, select, &.{.{ .int = 1 }});
    try std.testing.expectEqualStrings(value, binary.value.rows.items[0].values[0].?);
    try std.testing.expectEqual(@as(u8, 246), binary.value.rows.columns[0].type_code);
    binary.deinit();
}
