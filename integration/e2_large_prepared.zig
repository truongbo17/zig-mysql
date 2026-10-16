const std = @import("std");
const mysql = @import("zig_mysql");

/// One value crosses at least two MySQL classic packets in both directions.
/// Data is intentionally non-UTF8 binary; no text conversion is permitted.
pub fn verify(conn: *mysql.Client, io: std.Io) !void {
    const len: usize = mysql.protocol.max_packet_payload + 257;
    const payload = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(payload);
    for (payload, 0..) |*byte, i| byte.* = @truncate((i *% 131 +% 17) >> 4);
    payload[0] = 0;
    payload[1] = 0xff;
    payload[len - 1] = 0xfe;

    var stmt = try conn.prepare(io, "SELECT ?");
    defer conn.closeStatement(io, &stmt) catch {};
    var response = try conn.execute(io, stmt, &.{.{ .bytes = payload }});
    defer response.deinit();
    const result = response.value.rows.items[0].values[0].?;
    try std.testing.expectEqual(payload.len, result.len);
    try std.testing.expectEqualSlices(u8, payload, result);
    try conn.ping(io); // proves the multi-packet exchange remained synchronized
}
