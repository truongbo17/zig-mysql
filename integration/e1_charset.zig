const std = @import("std");
const mysql = @import("zig_mysql");

/// Exercises a fresh connection's advertised collation and SQL-mode
/// semantics. Never interpolate user data into SQL under ANSI_QUOTES or
/// NO_BACKSLASH_ESCAPES; binary prepared parameters must remain byte-exact.
pub fn verify(conn: *mysql.Client, io: std.Io) !void {
    var settings = try conn.query(io,
        "SELECT @@character_set_client, @@character_set_connection, @@character_set_results, @@collation_connection");
    defer settings.deinit();
    const row = settings.value.rows.items[0].values;
    try std.testing.expectEqualStrings("utf8mb4", row[0].?);
    try std.testing.expectEqualStrings("utf8mb4", row[1].?);
    try std.testing.expectEqualStrings("utf8mb4", row[2].?);
    try std.testing.expectEqualStrings("utf8mb4_unicode_ci", row[3].?);

    var mode = try conn.query(io,
        "SET SESSION sql_mode = 'ANSI_QUOTES,NO_BACKSLASH_ESCAPES'");
    mode.deinit();
    var timezone = try conn.query(io, "SET SESSION time_zone = '+07:00'");
    timezone.deinit();

    var query_mode = try conn.query(io, "SELECT @@session.sql_mode, @@session.time_zone");
    defer query_mode.deinit();
    const state = query_mode.value.rows.items[0].values;
    try std.testing.expect(std.mem.indexOf(u8, state[0].?, "ANSI_QUOTES") != null);
    try std.testing.expect(std.mem.indexOf(u8, state[0].?, "NO_BACKSLASH_ESCAPES") != null);
    try std.testing.expectEqualStrings("+07:00", state[1].?);

    // Double quotes are identifiers under ANSI_QUOTES, not strings.
    var stmt = try conn.prepare(io, "SELECT ? AS \"tên\"");
    defer conn.closeStatement(io, &stmt) catch {};
    const original = "Tiếng Việt: Trần Đặng, \"nháy\", \\backslash, 'apostrophe', \x00nul";
    var result = try conn.execute(io, stmt, &.{.{ .text = original }});
    defer result.deinit();
    try std.testing.expectEqualStrings("tên", result.value.rows.columns[0].name);
    try std.testing.expectEqualStrings(original, result.value.rows.items[0].values[0].?);

    // Normal SQL and pooled use still work after changing session modes.
    var ping = try conn.query(io, "SELECT 42");
    defer ping.deinit();
    try std.testing.expectEqualStrings("42", ping.value.rows.items[0].values[0].?);
}
