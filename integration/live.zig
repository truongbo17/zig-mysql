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

test "pool timed acquisition fails closed on blocking TLS transport" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33306") },
            .username = "zigtest",
            .password = "zig_mysql_test",
            .tls = .{ .host = "mysql.example.invalid" },
        },
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit(io);
    try std.testing.expectError(error.TimedTlsUnsupported, pool.acquireWithTimeout(io, .fromSeconds(1)));
    try std.testing.expectEqual(@as(usize, 0), pool.stats(io).open);
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
