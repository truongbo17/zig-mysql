const std = @import("std");
const mysql = @import("zig_mysql");

extern "c" fn getenv([*:0]const u8) ?[*:0]const u8;

fn config(port: u16) !mysql.Config {
    const address = try std.fmt.allocPrint(std.testing.allocator, "127.0.0.1:{d}", .{port});
    defer std.testing.allocator.free(address);
    return .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral(address) },
        .username = "zigtest",
        .password = "zig_mysql_test",
        .database = "zigtest",
    };
}

test "real replica is read-only and rejected by writer-only pool before promotion" {
    if (getenv("REPLICATION_PHASE") == null or
        !std.mem.eql(u8, std.mem.span(getenv("REPLICATION_PHASE").?), "before"))
        return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var observer = try mysql.Client.connect(std.testing.allocator, io, try config(33313));
    defer observer.deinit(io);
    var replicated = try observer.queryWithTimeout(io, "SELECT note FROM failover_probe WHERE id=1", .fromSeconds(2));
    try std.testing.expectEqualStrings("replicated", replicated.value.rows.items[0].values[0].?);
    replicated.deinit();

    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = try config(33313),
        .require_writable = true,
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit(io);
    try std.testing.expectError(error.ReadOnlyServer, pool.acquireWithTimeout(io, .fromSeconds(4)));
    const stats = pool.stats(io);
    try std.testing.expectEqual(@as(usize, 0), stats.open);
    try std.testing.expectEqual(@as(usize, 1), stats.read_only_rejections);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);
}

test "promoted replica accepts writer-only fallback after old primary stops" {
    if (getenv("REPLICATION_PHASE") == null or
        !std.mem.eql(u8, std.mem.span(getenv("REPLICATION_PHASE").?), "after"))
        return error.SkipZigTest;

    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var pool = try mysql.Pool.init(std.testing.allocator, .{
        .connection = try config(33312), // stopped/fenced former primary
        .failover_addresses = &.{ .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33313") } },
        .require_writable = true,
        .connect_attempt_timeout = .fromSeconds(2),
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit(io);
    const writer = try pool.acquireWithTimeout(io, .fromSeconds(5));
    var original = try writer.queryWithTimeout(io, "SELECT note FROM failover_probe WHERE id=1", .fromSeconds(2));
    try std.testing.expectEqualStrings("replicated", original.value.rows.items[0].values[0].?);
    original.deinit();
    var inserted = try writer.queryWithTimeout(io, "INSERT INTO failover_probe (id, note) VALUES (2, 'promoted')", .fromSeconds(2));
    inserted.deinit();
    pool.release(io, writer);

    const recycled = try pool.acquireWithTimeout(io, .fromSeconds(5));
    var check = try recycled.queryWithTimeout(io, "SELECT note FROM failover_probe WHERE id=2", .fromSeconds(2));
    try std.testing.expectEqualStrings("promoted", check.value.rows.items[0].values[0].?);
    check.deinit();
    pool.release(io, recycled);

    const stats = pool.stats(io);
    try std.testing.expectEqual(@as(usize, 1), stats.failover_attempts);
    try std.testing.expectEqual(@as(usize, 1), stats.failover_successes);
    try std.testing.expectEqual(@as(usize, 0), stats.read_only_rejections);
    try std.testing.expectEqual(@as(usize, 0), stats.in_use);
}
