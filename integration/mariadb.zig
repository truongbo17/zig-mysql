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

test "MariaDB strict temporal decoding from text and binary prepared rows" {
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

    var setup = try conn.query(io,
        "CREATE TEMPORARY TABLE zig_temporal_test (d DATE, dt DATETIME(6), t TIME(6))");
    setup.deinit();
    var inserted = try conn.query(io,
        "INSERT INTO zig_temporal_test VALUES ('2024-02-29', '2024-02-29 23:59:59.123456', '-837:59:59.999999')");
    inserted.deinit();

    var text = try conn.query(io, "SELECT d, dt, t FROM zig_temporal_test");
    const row = text.value.rows.items[0];
    const d = try mysql.Temporal.parseDate(row.values[0].?);
    const dt = try mysql.Temporal.parseDateTime(row.values[1].?);
    const duration = try mysql.Temporal.parseTime(row.values[2].?);
    try std.testing.expectEqual(@as(u16, 2024), d.year);
    try std.testing.expectEqual(@as(u8, 29), d.day);
    try std.testing.expectEqual(@as(u32, 123456), dt.microsecond);
    try std.testing.expect(duration.negative);
    try std.testing.expectEqual(@as(u16, 837), duration.hours);
    text.deinit();

    var statement = try conn.prepare(io, "SELECT d, dt, t FROM zig_temporal_test WHERE d = ?");
    defer conn.closeStatement(io, &statement) catch {};
    var binary = try conn.execute(io, statement, &.{.{ .text = "2024-02-29" }});
    const b = binary.value.rows.items[0];
    try std.testing.expectEqual(@as(u8, 10), binary.value.rows.columns[0].type_code);
    try std.testing.expectEqual(@as(u8, 12), binary.value.rows.columns[1].type_code);
    try std.testing.expectEqual(@as(u8, 11), binary.value.rows.columns[2].type_code);
    _ = try mysql.Temporal.parseDate(b.values[0].?);
    const bdt = try mysql.Temporal.parseDateTime(b.values[1].?);
    try std.testing.expectEqual(@as(u32, 123456), bdt.microsecond);
    const bt = try mysql.Temporal.parseTime(b.values[2].?);
    try std.testing.expectEqual(@as(u32, 999999), bt.microsecond);
    binary.deinit();
}

test "MariaDB typed prepared binary result scanner keeps SQL types, unsignedness and NULL" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conn = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33308") },
        .username = "zigtest", .password = "zig_mysql_test", .database = "zigtest",
    });
    defer conn.deinit(io);
    var created = try conn.query(io,
        "CREATE TEMPORARY TABLE zig_prepared_scan (id INT PRIMARY KEY, signed_value BIGINT, unsigned_value BIGINT UNSIGNED, amount DECIMAL(12,4), d DATE, dt DATETIME(6), duration TIME(6), payload BLOB, note VARCHAR(32), maybe BIGINT)");
    created.deinit();
    var ins = try conn.prepare(io,
        "INSERT INTO zig_prepared_scan VALUES(1,?,?,?,?,?,?,?,?,?)");
    defer conn.closeStatement(io, &ins) catch {};
    const raw = &[_]u8{ 0, 0xff, 0x80, 42 };
    var inserted = try conn.execute(io, ins, &.{
        .{ .int = -42 }, .{ .uint = std.math.maxInt(u64) },
        .{ .decimal = "123456.4500" }, .{ .text = "2024-02-29" },
        .{ .text = "2024-02-29 12:34:56.000012" }, .{ .text = "-837:12:11.001002" },
        .{ .bytes = raw }, .{ .text = "Việt Nam" }, .null,
    });
    inserted.deinit();
    var stmt = try conn.prepare(io,
        "SELECT signed_value, unsigned_value, amount, d, dt, duration, payload, note, maybe FROM zig_prepared_scan WHERE id=?");
    defer conn.closeStatement(io, &stmt) catch {};
    var res = try conn.execute(io, stmt, &.{.{ .int = 1 }});
    defer res.deinit();
    const scanner = try mysql.PreparedRow.init(res.value.rows, 0);
    try std.testing.expectEqual(@as(i64, -42), (try scanner.int(0)).?);
    try std.testing.expectEqual(std.math.maxInt(u64), (try scanner.uint(1)).?);
    try std.testing.expectError(error.ColumnTypeMismatch, scanner.int(1));
    try std.testing.expectEqualStrings("123456.4500", (try scanner.exactDecimal(2)).?.bytes);
    try std.testing.expectEqual(@as(u8, 29), (try scanner.date(3)).?.day);
    try std.testing.expectEqual(@as(u32, 12), (try scanner.dateTime(4)).?.microsecond);
    try std.testing.expect((try scanner.time(5)).?.negative);
    try std.testing.expectEqualSlices(u8, raw, (try scanner.bytes(6)).?);
    try std.testing.expectError(error.InvalidUtf8, scanner.string(6));
    try std.testing.expectEqualStrings("Việt Nam", (try scanner.string(7)).?);
    try std.testing.expect((try scanner.int(8)) == null);
    try std.testing.expectError(error.RowOutOfRange, mysql.PreparedRow.init(res.value.rows, 1));

    // A caller may not reuse a server prepared statement after resetting
    // the session. New prepared statements on the same socket remain valid.
    try conn.closeStatement(io, &stmt);
    try conn.closeStatement(io, &ins);
    try conn.resetConnection(io);
    var ping = try conn.query(io, "SELECT 1");
    defer ping.deinit();
    try std.testing.expectEqualStrings("1", ping.value.rows.items[0].values[0].?);
}
