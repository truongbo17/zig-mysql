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

    // A row larger than one classic packet must be reassembled correctly.
    var large = try client.query(io, "SELECT REPEAT('z', 16777216)");
    defer large.deinit();
    const text = large.value.rows.items[0].values[0].?;
    try std.testing.expectEqual(@as(usize, 16777216), text.len);
    try std.testing.expectEqual(@as(u8, 'z'), text[text.len - 1]);

    var stream = try client.queryRows(io, "SELECT id, label FROM sample ORDER BY id");
    try std.testing.expectError(error.RowsNotConsumed, client.ping(io));
    const first_row = (try stream.next(io)).?;
    try std.testing.expectEqualStrings("1", first_row.values[0].?);
    stream.deinit(io); // drains the unread rows
    try client.ping(io);
}

test "connection pool caps capacity and resets sessions between borrowers" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
            .username = "zigtest",
            .password = "zig_mysql_test",
            .database = "zigtest",
        },
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit(io);

    const first = try pool.acquire(io);
    try std.testing.expectError(error.PoolExhausted, pool.tryAcquire(io));

    var set_variable = try first.query(io, "SET @zig_pool_marker = 123");
    set_variable.deinit();
    var create_temp = try first.query(io, "CREATE TEMPORARY TABLE zig_pool_temp (id INT)");
    create_temp.deinit();

    pool.release(io, first);
    const idle_stats = pool.stats(io);
    try std.testing.expectEqual(@as(usize, 1), idle_stats.open);
    try std.testing.expectEqual(@as(usize, 1), idle_stats.idle);
    try std.testing.expectEqual(@as(usize, 0), idle_stats.in_use);

    const reused = try pool.acquire(io);
    try std.testing.expect(first == reused);
    var check_variable = try reused.query(io, "SELECT @zig_pool_marker");
    try std.testing.expectEqual(@as(?[]const u8, null), check_variable.value.rows.items[0].values[0]);
    check_variable.deinit();

    // Reset removes temporary tables and preserves the configured schema.
    try std.testing.expectError(error.ServerError, reused.query(io, "SELECT * FROM zig_pool_temp"));
    var schema = try reused.query(io, "SELECT DATABASE()");
    try std.testing.expectEqualStrings("zigtest", schema.value.rows.items[0].values[0].?);
    schema.deinit();

    // Ordinary SQL errors are recoverable; the connection can still be pooled.
    pool.release(io, reused);
    const third = try pool.acquire(io);
    try third.ping(io);

    // A broken connection is evicted instead of being handed out again.
    third.broken = true;
    pool.release(io, third);
    const after_evict = pool.stats(io);
    try std.testing.expectEqual(@as(usize, 0), after_evict.open);

    const replacement = try pool.acquire(io);
    try replacement.ping(io);
    pool.release(io, replacement);
}

test "buffered query and prepared execute deadlines protect pooled connections" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
            .username = "zigtest",
            .password = "zig_mysql_test",
            .database = "zigtest",
        },
        .max_open = 1,
        .max_idle = 1,
        .health_check_timeout = .fromSeconds(2),
    });
    defer pool.deinit(io);

    const connection = try pool.acquire(io);
    var fast = try connection.queryWithTimeout(io, "SELECT 42", .fromSeconds(2));
    try std.testing.expectEqualStrings("42", fast.value.rows.items[0].values[0].?);
    fast.deinit();

    var statement = try connection.prepare(io, "SELECT ? + 1");
    var executed = try connection.executeWithTimeout(io, statement, &.{.{ .int = 2 }}, .fromSeconds(2));
    try std.testing.expectEqualStrings("3", executed.value.rows.items[0].values[0].?);
    executed.deinit();
    try connection.closeStatement(io, &statement);

    try std.testing.expectError(error.QueryTimeout, connection.queryWithTimeout(io, "SELECT SLEEP(2)", .fromMilliseconds(50)));
    try std.testing.expect(connection.broken);
    try std.testing.expectError(error.ConnectionBroken, connection.ping(io));
    pool.release(io, connection);
    try std.testing.expectEqual(@as(usize, 0), pool.stats(io).open);

    const fresh = try pool.acquire(io);
    try fresh.pingWithTimeout(io, .fromSeconds(2));
    pool.release(io, fresh);
}

test "pool health check evicts idle connections killed by server" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const config = mysql.Config{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
        .username = "zigtest",
        .password = "zig_mysql_test",
        .database = "zigtest",
    };
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = config,
        .max_open = 1,
        .max_idle = 1,
        .health_check_timeout = .fromSeconds(2),
    });
    defer pool.deinit(io);

    const first = try pool.acquire(io);
    var id_result = try first.query(io, "SELECT CONNECTION_ID()");
    const id = try std.fmt.parseInt(u64, id_result.value.rows.items[0].values[0].?, 10);
    id_result.deinit();
    pool.release(io, first);

    var killer = try mysql.Client.connect(std.testing.allocator, io, config);
    defer killer.deinit(io);
    const kill_sql = try std.fmt.allocPrint(std.testing.allocator, "KILL CONNECTION {d}", .{id});
    defer std.testing.allocator.free(kill_sql);
    var killed = try killer.query(io, kill_sql);
    killed.deinit();

    const replacement = try pool.acquire(io);
    try replacement.ping(io);
    try std.testing.expectEqual(@as(usize, 1), pool.stats(io).health_check_failures);
    var new_id_result = try replacement.query(io, "SELECT CONNECTION_ID()");
    const new_id = try std.fmt.parseInt(u64, new_id_result.value.rows.items[0].values[0].?, 10);
    new_id_result.deinit();
    try std.testing.expect(id != new_id);
    pool.release(io, replacement);
}

test "pool acquisition deadline expires without leaking an in-use slot" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
            .username = "zigtest",
            .password = "zig_mysql_test",
            .database = "zigtest",
        },
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit(io);

    const occupied = try pool.acquire(io);
    try std.testing.expectError(error.PoolAcquireTimeout, pool.acquireWithTimeout(io, .fromMilliseconds(40)));
    const full = pool.stats(io);
    try std.testing.expectEqual(@as(usize, 1), full.open);
    try std.testing.expectEqual(@as(usize, 0), full.idle);
    try std.testing.expectEqual(@as(usize, 1), full.in_use);

    pool.release(io, occupied);
    const returned = try pool.acquireWithTimeout(io, .fromSeconds(2));
    try returned.ping(io);
    pool.release(io, returned);
    try std.testing.expectEqual(@as(usize, 1), pool.stats(io).idle);
}

test "pool zero-idle mode discards connections before freeing capacity" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
            .username = "zigtest",
            .password = "zig_mysql_test",
            .database = "zigtest",
        },
        .max_open = 1,
        .max_idle = 0,
    });
    defer pool.deinit(io);

    for (0..12) |_| {
        const connection = try pool.acquireWithTimeout(io, .fromSeconds(2));
        var response = try connection.query(io, "SELECT 1");
        try std.testing.expectEqualStrings("1", response.value.rows.items[0].values[0].?);
        response.deinit();
        pool.release(io, connection);
        const stats = pool.stats(io);
        try std.testing.expectEqual(@as(usize, 0), stats.open);
        try std.testing.expectEqual(@as(usize, 0), stats.idle);
    }
}

test "stream row timeout poisons the session without blocking deinit" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
            .username = "zigtest",
            .password = "zig_mysql_test",
            .database = "zigtest",
        },
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit(io);

    const connection = try pool.acquire(io);
    var fast = try connection.queryRowsWithTimeout(io, "SELECT 1", .fromSeconds(2));
    try std.testing.expectEqualStrings("1", (try fast.nextWithTimeout(io, .fromSeconds(2))).?.values[0].?);
    try std.testing.expect((try fast.nextWithTimeout(io, .fromSeconds(2))) == null);
    fast.deinit(io);

    // SELECT SLEEP may be evaluated before the server transmits metadata;
    // an early deadline must poison the socket even if no stream exists yet.
    try std.testing.expectError(error.QueryTimeout, connection.queryRowsWithTimeout(io, "SELECT SLEEP(2)", .fromMilliseconds(50)));
    try std.testing.expect(connection.broken);
    pool.release(io, connection);
    try std.testing.expectEqual(@as(usize, 0), pool.stats(io).open);
    const new_connection = try pool.acquire(io);
    try new_connection.ping(io);
    pool.release(io, new_connection);
}

test "pool idle age and connection age recycle at safe boundaries" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const config: mysql.Config = .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
        .username = "zigtest",
        .password = "zig_mysql_test",
        .database = "zigtest",
    };
    var idle_pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = config,
        .max_open = 1,
        .max_idle = 1,
        .max_idle_time = .fromMilliseconds(0),
    });
    defer idle_pool.deinit(io);

    const first = try idle_pool.acquire(io);
    var first_id = try first.query(io, "SELECT CONNECTION_ID()");
    const a = try std.fmt.parseInt(u64, first_id.value.rows.items[0].values[0].?, 10);
    first_id.deinit();
    idle_pool.release(io, first);
    try std.testing.expectEqual(@as(usize, 1), idle_pool.stats(io).idle);

    const next = try idle_pool.acquire(io);
    var second_id = try next.query(io, "SELECT CONNECTION_ID()");
    const b = try std.fmt.parseInt(u64, second_id.value.rows.items[0].values[0].?, 10);
    second_id.deinit();
    try std.testing.expect(a != b);
    try std.testing.expectEqual(@as(usize, 1), idle_pool.stats(io).expired_connections);
    idle_pool.release(io, next);

    var life_pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = config,
        .max_open = 1,
        .max_idle = 1,
        .max_connection_age = .fromMilliseconds(0),
    });
    defer life_pool.deinit(io);

    const aged = try life_pool.acquire(io);
    try aged.ping(io);
    life_pool.release(io, aged);
    try std.testing.expectEqual(@as(usize, 0), life_pool.stats(io).open);
    try std.testing.expectEqual(@as(usize, 1), life_pool.stats(io).expired_connections);
    const replacement = try life_pool.acquire(io);
    try replacement.ping(io);
    life_pool.release(io, replacement);
}

test "streaming row deadline cancels a multi-packet row and evicts its connection" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
            .username = "zigtest",
            .password = "zig_mysql_test",
            .database = "zigtest",
        },
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit(io);

    const connection = try pool.acquire(io);
    var stream = try connection.queryRows(io, "SELECT REPEAT('x', 16777216)");
    // A 16-MiB+ row cannot be delivered in one bounded TCP read; an
    // immediate deadline must stop row reassembly and poison the socket.
    try std.testing.expectError(error.QueryTimeout, stream.nextWithTimeout(io, .fromMilliseconds(0)));
    try std.testing.expect(connection.broken);
    stream.deinit(io); // must not wait for the rest of the oversized row
    pool.release(io, connection);
    try std.testing.expectEqual(@as(usize, 0), pool.stats(io).open);

    const fresh = try pool.acquire(io);
    var healthy = try fresh.query(io, "SELECT 1");
    try std.testing.expectEqualStrings("1", healthy.value.rows.items[0].values[0].?);
    healthy.deinit();
    pool.release(io, fresh);
}

test "pool connects to healthy fallback when primary connection is unavailable" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33399") },
            .username = "zigtest",
            .password = "zig_mysql_test",
            .database = "zigtest",
        },
        .failover_addresses = &.{
            .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33398") },
            .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
        },
        .connect_attempt_timeout = .fromMilliseconds(400),
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit(io);

    const connection = try pool.acquireWithTimeout(io, .fromSeconds(4));
    var result = try connection.queryWithTimeout(io, "SELECT DATABASE()", .fromSeconds(2));
    try std.testing.expectEqualStrings("zigtest", result.value.rows.items[0].values[0].?);
    result.deinit();
    pool.release(io, connection);

    const stats = pool.stats(io);
    try std.testing.expectEqual(@as(usize, 2), stats.failover_attempts);
    try std.testing.expectEqual(@as(usize, 1), stats.failover_successes);
    try std.testing.expectEqual(@as(usize, 2), stats.connect_failures);
    try std.testing.expectEqual(@as(usize, 1), stats.connections_created);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);
}

test "pool never succeeds when all failover endpoints are unavailable" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33399") },
            .username = "zigtest",
            .password = "zig_mysql_test",
        },
        .failover_addresses = &.{
            .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33398") },
        },
        .connect_attempt_timeout = .fromMilliseconds(300),
        .max_open = 1,
        .max_idle = 0,
    });
    defer pool.deinit(io);

    _ = pool.acquireWithTimeout(io, .fromSeconds(3)) catch {
        const stats = pool.stats(io);
        try std.testing.expectEqual(@as(usize, 0), stats.open);
        try std.testing.expectEqual(@as(usize, 0), stats.in_use);
        try std.testing.expectEqual(@as(usize, 1), stats.failover_attempts);
        try std.testing.expectEqual(@as(usize, 0), stats.failover_successes);
        try std.testing.expectEqual(@as(usize, 2), stats.connect_failures);
        return;
    };
    return error.UnexpectedSuccessfulConnection;
}

test "failover refuses to bypass primary authentication failure" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
            .username = "zigtest",
            .password = "intentionally_wrong_password",
            .database = "zigtest",
        },
        .failover_addresses = &.{
            .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
        },
        .connect_attempt_timeout = .fromSeconds(2),
        .max_open = 1,
        .max_idle = 0,
    });
    defer pool.deinit(io);
    try std.testing.expectError(error.ServerError, pool.acquireWithTimeout(io, .fromSeconds(4)));
    const stats = pool.stats(io);
    try std.testing.expectEqual(@as(usize, 0), stats.failover_attempts);
    try std.testing.expectEqual(@as(usize, 0), stats.failover_successes);
    try std.testing.expectEqual(@as(usize, 1), stats.connect_failures);
    try std.testing.expectEqual(@as(usize, 0), stats.open);
}

test "MySQL 8.0 lossless DECIMAL binding and binary/text roundtrip" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conn = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
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

test "MySQL 8.0 strict temporal decoding from text and binary prepared rows" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conn = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
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

test "typed text row scanner integration: nullable decimal and streamed SELECT" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var connection = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
        .username = "zigtest", .password = "zig_mysql_test", .database = "zigtest",
    });
    defer connection.deinit(io);
    var result = try connection.query(io,
        "SELECT CAST(123456789.0050 AS DECIMAL(14,4)), CAST(NULL AS SIGNED), CAST('2024-02-29' AS DATE), CAST(1 AS UNSIGNED)");
    defer result.deinit();
    const scan = mysql.TextRow.init(result.value.rows.items[0]);
    try std.testing.expectEqualStrings("123456789.0050", (try scan.exactDecimal(0)).?.bytes);
    try std.testing.expect((try scan.int(1)) == null);
    try std.testing.expectEqual(@as(u8, 29), (try scan.date(2)).?.day);
    try std.testing.expectEqual(@as(u64, 1), (try scan.uint(3)).?);

    var stream = try connection.queryRows(io, "SELECT 10 UNION ALL SELECT 20");
    defer stream.deinit(io);
    const first = mysql.TextRow.init((try stream.next(io)).?);
    try std.testing.expectEqual(@as(i64, 10), (try first.int(0)).?);
    const second = mysql.TextRow.init((try stream.next(io)).?);
    try std.testing.expectEqual(@as(i64, 20), (try second.int(0)).?);
    try std.testing.expect((try stream.next(io)) == null);
}

test "MySQL 8.0 native binary prepared DATE, DATETIME, TIME and TIMESTAMP roundtrip" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conn = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
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

test "MySQL 8.0 JSON and BLOB preserve explicit byte and UTF8 semantics" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var conn = try mysql.Client.connect(std.testing.allocator, io, .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
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
