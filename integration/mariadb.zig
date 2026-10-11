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

test "MariaDB native binary prepared DATE, DATETIME, TIME and TIMESTAMP roundtrip" {
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
    var timezone = try conn.query(io, "SET time_zone = '+00:00'");
    timezone.deinit();
    var created = try conn.query(io,
        "CREATE TEMPORARY TABLE zig_temporal_bind (d DATE, dt DATETIME(6), t TIME(6), ts TIMESTAMP(6))");
    created.deinit();

    var ins = try conn.prepare(io, "INSERT INTO zig_temporal_bind VALUES (?, ?, ?, ?)");
    defer conn.closeStatement(io, &ins) catch {};
    const date = mysql.Temporal.Date{ .year = 2024, .month = 2, .day = 29 };
    const dt = mysql.Temporal.DateTime{
        .date = date, .hour = 23, .minute = 59, .second = 59,
        .microsecond = 123456, .fractional_digits = 6,
    };
    const tm = mysql.Temporal.Time{
        .negative = true, .hours = 837, .minutes = 59, .seconds = 59,
        .microsecond = 999999, .fractional_digits = 6,
    };
    const ts = mysql.Temporal.DateTime{
        .date = date, .hour = 1, .minute = 2, .second = 3,
        .microsecond = 12, .fractional_digits = 6,
    };
    try std.testing.expectError(error.InvalidTemporal, conn.execute(io, ins,
        &.{ .{ .date = .{ .year = 2023, .month = 2, .day = 29 } },
            .{ .datetime = dt }, .{ .time = tm }, .{ .timestamp = ts } }));
    try conn.ping(io);

    var written = try conn.execute(io, ins, &.{
        .{ .date = date }, .{ .datetime = dt },
        .{ .time = tm }, .{ .timestamp = ts },
    });
    try std.testing.expectEqual(@as(u64, 1), written.value.ok.affected_rows);
    written.deinit();
    var text = try conn.query(io, "SELECT d, dt, t, ts FROM zig_temporal_bind");
    const values = text.value.rows.items[0].values;
    _ = try mysql.Temporal.parseDate(values[0].?);
    const outdt = try mysql.Temporal.parseDateTime(values[1].?);
    try std.testing.expectEqual(@as(u32, 123456), outdt.microsecond);
    const outtime = try mysql.Temporal.parseTime(values[2].?);
    try std.testing.expect(outtime.negative);
    try std.testing.expectEqual(@as(u16, 837), outtime.hours);
    try std.testing.expectEqual(@as(u32, 999999), outtime.microsecond);
    const outts = try mysql.Temporal.parseDateTime(values[3].?);
    try std.testing.expectEqual(@as(u32, 12), outts.microsecond);
    text.deinit();

    var select = try conn.prepare(io, "SELECT d, dt, t, ts FROM zig_temporal_bind");
    defer conn.closeStatement(io, &select) catch {};
    var binary = try conn.execute(io, select, &.{});
    const b = binary.value.rows.items[0].values;
    _ = try mysql.Temporal.parseDate(b[0].?);
    try std.testing.expectEqual(@as(u32, 123456),
        (try mysql.Temporal.parseDateTime(b[1].?)).microsecond);
    try std.testing.expectEqual(@as(u32, 999999),
        (try mysql.Temporal.parseTime(b[2].?)).microsecond);
    try std.testing.expectEqual(@as(u32, 12),
        (try mysql.Temporal.parseDateTime(b[3].?)).microsecond);
    binary.deinit();
}

test "MariaDB JSON and BLOB preserve explicit byte and UTF8 semantics" {
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
        "CREATE TEMPORARY TABLE zig_bytes_roundtrip (id INT PRIMARY KEY, raw_data LONGBLOB, payload JSON)");
    create.deinit();

    const original = &[_]u8{ 0, 0xff, 0xfe, 0x61, 0, 0x80 };
    const blob = mysql.SqlBytes.blob(original);
    const payload = try mysql.SqlBytes.json(std.testing.allocator,
        "{\"xin_chao\":\"Việt Nam\",\"n\":42}");
    var stmt = try conn.prepare(io,
        "INSERT INTO zig_bytes_roundtrip VALUES (1, ?, ?)");
    defer conn.closeStatement(io, &stmt) catch {};
    var inserted = try conn.execute(io, stmt,
        &.{ .{ .bytes = blob.bytes }, .{ .text = payload.bytes } });
    try std.testing.expectEqual(@as(u64, 1), inserted.value.ok.affected_rows);
    inserted.deinit();

    var select = try conn.prepare(io,
        "SELECT raw_data FROM zig_bytes_roundtrip WHERE id=1");
    defer conn.closeStatement(io, &select) catch {};
    var binary = try conn.execute(io, select, &.{});
    const returned = mysql.SqlBytes.blob(binary.value.rows.items[0].values[0].?);
    try std.testing.expectEqualSlices(u8, original, returned.bytes);
    try std.testing.expectError(error.InvalidUtf8, mysql.SqlBytes.text(returned.bytes));
    binary.deinit();

    var json_result = try conn.query(io,
        "SELECT payload, JSON_EXTRACT(payload, '$.n') FROM zig_bytes_roundtrip");
    const returned_json = try mysql.SqlBytes.json(std.testing.allocator,
        json_result.value.rows.items[0].values[0].?);
    try std.testing.expectEqual(mysql.SqlBytes.Kind.json, returned_json.kind);
    try std.testing.expectEqualStrings("42", json_result.value.rows.items[0].values[1].?);
    json_result.deinit();
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

test "MariaDB CALL multi-result framing, drain and reuse" {
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

    var cleanup = try conn.query(io, "DROP PROCEDURE IF EXISTS zig_b1_multi_result");
    cleanup.deinit();
    var created = try conn.query(io,
        "CREATE PROCEDURE zig_b1_multi_result() BEGIN SELECT 11 AS first_result; SELECT 22 AS empty_result WHERE 1=0; SELECT 33 AS third_result; END");
    created.deinit();

    var multi = try conn.queryAll(io, "CALL zig_b1_multi_result()");
    defer multi.deinit();
    try std.testing.expect(multi.items.len >= 4);
    try std.testing.expectEqualStrings("11", multi.items[0].value.rows.items[0].values[0].?);
    try std.testing.expectEqual(@as(usize, 0), multi.items[1].value.rows.items.len);
    try std.testing.expectEqualStrings("33", multi.items[2].value.rows.items[0].values[0].?);
    try std.testing.expect(multi.items[multi.items.len - 1].value == .ok);
    try conn.ping(io);

    // Existing single-result API must detect additional results rather than
    // leave an unread CALL result queued for the next command.
    try std.testing.expectError(error.MultipleResults, conn.query(io, "CALL zig_b1_multi_result()"));
    try std.testing.expect(!conn.broken);
    try conn.ping(io);

    var stream = try conn.queryRows(io, "CALL zig_b1_multi_result()");
    try std.testing.expectEqualStrings("11", (try stream.next(io)).?.values[0].?);
    try std.testing.expectError(error.MultipleResults, stream.next(io));
    stream.deinit(io);
    try std.testing.expect(!conn.broken);
    try conn.ping(io);

    var removed = try conn.query(io, "DROP PROCEDURE zig_b1_multi_result");
    removed.deinit();

    var old_error = try conn.query(io, "DROP PROCEDURE IF EXISTS zig_b1_later_error");
    old_error.deinit();
    var bad = try conn.query(io,
        "CREATE PROCEDURE zig_b1_later_error() BEGIN SELECT 1 AS accepted; SELECT * FROM zig_b1_missing_table; END");
    bad.deinit();
    try std.testing.expectError(error.ServerError, conn.queryAll(io, "CALL zig_b1_later_error()"));
    try std.testing.expect(conn.broken);
    try std.testing.expectError(error.ConnectionBroken, conn.ping(io));
}

test "MariaDB B2 CALL result iterator IN OUT INOUT and early cleanup" {
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
    var removed = try conn.query(io, "DROP PROCEDURE IF EXISTS zig_b2_inout");
    removed.deinit();
    var create = try conn.query(io,
        "CREATE PROCEDURE zig_b2_inout(IN x INT, OUT doubled INT, INOUT acc INT) " ++
        "BEGIN SET doubled = x * 2; SET acc = acc + x; " ++
        "SELECT x AS first_result; SELECT 99 AS empty_result WHERE 1=0; END");
    create.deinit();
    var set_vars = try conn.query(io, "SET @zig_b2_doubled = NULL, @zig_b2_acc = 3");
    set_vars.deinit();

    var parts = try conn.callResults(io, "CALL zig_b2_inout(7, @zig_b2_doubled, @zig_b2_acc)");
    try std.testing.expectError(error.RowsNotConsumed, conn.ping(io));
    var count: usize = 0;
    while (try parts.next(io)) |part| {
        var owned = part;
        defer owned.deinit();
        if (count == 0) try std.testing.expectEqualStrings("7", owned.value.rows.items[0].values[0].?);
        if (count == 1) try std.testing.expectEqual(@as(usize, 0), owned.value.rows.items.len);
        count += 1;
    }
    try std.testing.expect(count >= 3);
    try std.testing.expect(parts.final_ok != null);
    parts.deinit(io);
    try conn.ping(io);
    var output = try conn.query(io, "SELECT @zig_b2_doubled, @zig_b2_acc");
    try std.testing.expectEqualStrings("14", output.value.rows.items[0].values[0].?);
    try std.testing.expectEqualStrings("10", output.value.rows.items[0].values[1].?);
    output.deinit();

    var early = try conn.callResults(io, "CALL zig_b2_inout(4, @zig_b2_doubled, @zig_b2_acc)");
    var first = (try early.next(io)).?;
    first.deinit();
    try std.testing.expectError(error.RowsNotConsumed, conn.ping(io));
    early.deinit(io); // memory-bounded drain of remaining rowset and final OK
    try std.testing.expect(!conn.broken);
    try conn.ping(io);
    var output2 = try conn.query(io, "SELECT @zig_b2_doubled, @zig_b2_acc");
    try std.testing.expectEqualStrings("8", output2.value.rows.items[0].values[0].?);
    try std.testing.expectEqualStrings("14", output2.value.rows.items[0].values[1].?);
    output2.deinit();

    var remove = try conn.query(io, "DROP PROCEDURE zig_b2_inout");
    remove.deinit();
    var abort = try conn.callResults(io, "SELECT 1");
    abort.abandon(); // deliberately never read the first response
    try std.testing.expect(conn.broken);
    try std.testing.expectError(error.ConnectionBroken, conn.ping(io));
    abort.deinit(io);
}

test "MariaDB B2 later error and deadline poison CALL session" {
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
    var drop = try conn.query(io, "DROP PROCEDURE IF EXISTS zig_b2_late");
    drop.deinit();
    var created = try conn.query(io, "CREATE PROCEDURE zig_b2_late() BEGIN SELECT 1 AS good_result; SELECT * FROM zig_b2_nonexistent; END");
    created.deinit();
    var results = try conn.callResults(io, "CALL zig_b2_late()");
    var first = (try results.next(io)).?;
    try std.testing.expectEqualStrings("1", first.value.rows.items[0].values[0].?);
    first.deinit();
    try std.testing.expectError(error.ServerError, results.next(io));
    try std.testing.expect(conn.broken);
    results.deinit(io);
    try std.testing.expectError(error.ConnectionBroken, conn.ping(io));

    var slow_conn = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33308") },
        .username = "zigtest",
        .password = "zig_mysql_test",
        .database = "zigtest",
    });
    defer slow_conn.deinit(io);
    var slow_drop = try slow_conn.query(io, "DROP PROCEDURE IF EXISTS zig_b2_slow");
    slow_drop.deinit();
    var slow_create = try slow_conn.query(io, "CREATE PROCEDURE zig_b2_slow() BEGIN SELECT SLEEP(2); END");
    slow_create.deinit();
    var slow = try slow_conn.callResults(io, "CALL zig_b2_slow()");
    try std.testing.expectError(error.QueryTimeout, slow.nextWithTimeout(io, .fromMilliseconds(50)));
    try std.testing.expect(slow_conn.broken);
    slow.deinit(io); // never drain after a canceled read
    try std.testing.expectError(error.ConnectionBroken, slow_conn.ping(io));
}

test "MariaDB B3 streaming binary prepared rows, NULL/BLOB and early drain" {
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
    var stmt = try conn.prepare(io,
        "SELECT CAST(? AS SIGNED) AS qty, ? AS payload, NULL AS absent " ++
        "UNION ALL SELECT -7, X'4142', NULL");
    defer conn.closeStatement(io, &stmt) catch {};
    try std.testing.expectError(error.ParameterCountMismatch, conn.executeRows(io, stmt, &.{}));
    try conn.ping(io);

    const blob = [_]u8{ 0, 0xff, 0, 'A' };
    var stream = try conn.executeRowsWithTimeout(io, stmt, &.{ .{ .int = 42 }, .{ .bytes = &blob } }, .fromSeconds(4));
    try std.testing.expect(stream.binary);
    try std.testing.expectEqual(@as(usize, 3), stream.columns.len);
    try std.testing.expectError(error.RowsNotConsumed, conn.ping(io));
    const first = (try stream.nextWithTimeout(io, .fromSeconds(4))).?;
    try std.testing.expectEqualStrings("42", first.values[0].?);
    try std.testing.expectEqualSlices(u8, &blob, first.values[1].?);
    try std.testing.expect(first.values[2] == null);
    const second = (try stream.next(io)).?;
    try std.testing.expectEqualStrings("-7", second.values[0].?);
    try std.testing.expectEqualStrings("AB", second.values[1].?);
    try std.testing.expect(second.values[2] == null);
    try std.testing.expect((try stream.next(io)) == null);
    stream.deinit(io);
    try conn.ping(io);

    var early = try conn.executeRows(io, stmt, &.{ .{ .int = 12 }, .{ .bytes = "hello" } });
    _ = (try early.next(io)).?;
    early.deinit(io);
    try std.testing.expect(!conn.broken);
    try conn.ping(io);
}

test "MariaDB B4 101000 prepared binary rows within 2 MiB client allocation" {
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const storage = try std.heap.page_allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.heap.page_allocator.free(storage);
    var fixed = std.heap.FixedBufferAllocator.init(storage);
    var conn = try mysql.Client.connect(fixed.allocator(), io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33308") },
        .username = "zigtest",
        .password = "zig_mysql_test",
        .database = "zigtest",
    });
    defer conn.deinit(io);

    var stmt = try conn.prepare(io,
        "WITH RECURSIVE a(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM a WHERE n<999), " ++
        "b(n) AS (SELECT 0 UNION ALL SELECT n+1 FROM b WHERE n<100) " ++
        "SELECT CAST(? AS SIGNED) + a.n*101 + b.n AS value FROM a CROSS JOIN b");
    defer conn.closeStatement(io, &stmt) catch {};
    const started = std.Io.Clock.awake.now(io);
    var rows = try conn.executeRows(io, stmt, &.{.{ .int = 100 }});
    var count: usize = 0;
    while (try rows.next(io)) |row| {
        try std.testing.expectEqual(@as(usize, 1), row.values.len);
        if (count == 0) try std.testing.expect(row.values[0].?.len > 0);
        count += 1;
    }
    rows.deinit(io);
    try std.testing.expectEqual(@as(usize, 101000), count);
    try conn.ping(io);
    const elapsed_ns: u64 = @intCast(@max(1, started.untilNow(io, .awake).toNanoseconds()));
    const throughput = @as(f64, @floatFromInt(count)) * 1_000_000_000.0 /
        @as(f64, @floatFromInt(elapsed_ns));
    std.debug.print("B4_STREAM_BENCH rows={d} elapsed_ns={d} rows_per_sec={d:.1} allocator_cap_bytes={d}\n",
        .{ count, elapsed_ns, throughput, storage.len });
}

test "MariaDB B4 prepared streaming timeout evicts saturated pool slot" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33308") },
            .username = "zigtest", .password = "zig_mysql_test", .database = "zigtest",
        },
        .max_open = 1, .max_idle = 1,
    });
    defer pool.deinit(io);
    const conn = try pool.acquireWithTimeout(io, .fromSeconds(5));
    const stmt = try conn.prepare(io, "SELECT SLEEP(2) AS suspended");
    const response = conn.executeRowsWithTimeout(io, stmt, &.{}, .fromMilliseconds(50));
    if (response) |value| {
        var rows = value;
        try std.testing.expectError(error.QueryTimeout, rows.nextWithTimeout(io, .fromMilliseconds(50)));
        rows.deinit(io);
    } else |err| {
        try std.testing.expect(err == error.QueryTimeout);
    }
    try std.testing.expect(conn.broken);
    pool.release(io, conn);
    try std.testing.expectEqual(@as(usize, 0), pool.stats(io).in_use);
    try std.testing.expect(pool.stats(io).open <= 1);
    const retry = try pool.acquireWithTimeout(io, .fromSeconds(5));
    try retry.ping(io);
    pool.release(io, retry);
}

test "MariaDB C3 bounded cached prepares LRU schema reset and pool isolation" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const cfg: mysql.Config = .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33308") },
        .username = "zigtest", .password = "zig_mysql_test", .database = "zigtest",
        .statement_cache_capacity = 2,
    };
    var conn = try mysql.Client.connect(std.testing.allocator, io, cfg);
    defer conn.deinit(io);
    var a = try conn.executeCached(io, "SELECT ? + 1", &.{.{ .int = 5 }});
    try std.testing.expectEqualStrings("6", a.value.rows.items[0].values[0].?);
    a.deinit();
    var b = try conn.executeCached(io, "SELECT ? + 1", &.{.{ .int = 6 }});
    b.deinit();
    var c = try conn.executeCached(io, "SELECT ? + 2", &.{.{ .int = 7 }});
    c.deinit();
    var d = try conn.executeCached(io, "SELECT ? + 3", &.{.{ .int = 8 }});
    d.deinit();
    const stats = conn.statementCacheStats();
    try std.testing.expectEqual(@as(usize, 2), stats.entries);
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 3), stats.misses);
    try std.testing.expectEqual(@as(u64, 1), stats.evictions);
    var e = try conn.executeCached(io, "SELECT ? + 1", &.{.{ .int = 11 }});
    try std.testing.expectEqualStrings("12", e.value.rows.items[0].values[0].?);
    e.deinit();
    try std.testing.expectEqual(@as(u64, 2), conn.statementCacheStats().evictions);
    try conn.selectDatabase(io, "information_schema");
    try std.testing.expectEqual(@as(usize, 0), conn.statementCacheStats().entries);
    try conn.selectDatabase(io, "zigtest");
    var f = try conn.executeCached(io, "SELECT ? + 1", &.{.{ .int = 12 }});
    f.deinit();
    try conn.resetConnection(io);
    try std.testing.expectEqual(@as(usize, 0), conn.statementCacheStats().entries);
    var g = try conn.executeCached(io, "SELECT ? + 1", &.{.{ .int = 13 }});
    g.deinit();
    try conn.ping(io);

    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = cfg, .max_open = 1, .max_idle = 1,
    });
    defer pool.deinit(io);
    const one = try pool.acquire(io);
    var p = try one.executeCached(io, "SELECT ? + 1", &.{.{ .int = 1 }});
    p.deinit();
    try std.testing.expectEqual(@as(usize, 1), one.statementCacheStats().entries);
    pool.release(io, one); // COM_RESET_CONNECTION drops server handles
    const another = try pool.acquire(io);
    try std.testing.expectEqual(@as(usize, 0), another.statementCacheStats().entries);
    var q = try another.executeCached(io, "SELECT ? + 1", &.{.{ .int = 2 }});
    try std.testing.expectEqualStrings("3", q.value.rows.items[0].values[0].?);
    q.deinit();
    pool.release(io, another);
}
