const std = @import("std");
const mysql = @import("client.zig");
const text = @import("text_scan.zig");
const decimal = @import("decimal.zig");
const temporal = @import("temporal.zig");

/// Checked, allocation-free typed access to buffered COM_STMT_EXECUTE rows.
///
/// IMPORTANT: Client.execute() decodes the binary wire protocol into
/// Result-owned byte strings. This adapter applies column type/unsigned
/// metadata checks before reuse of strict TextRow parsers. The adapter and
/// all borrowed return values expire when Result.deinit() is called.
/// Only initialize from Client.execute(...).value.rows, not COM_QUERY rows.
pub const PreparedRow = struct {
    columns: []const mysql.Column,
    row: mysql.Row,

    pub fn init(rows: mysql.Rows, index: usize) !PreparedRow {
        if (index >= rows.items.len) return error.RowOutOfRange;
        if (rows.items[index].values.len != rows.columns.len) return error.ColumnCountMismatch;
        return .{ .columns = rows.columns, .row = rows.items[index] };
    }

    fn entry(self: PreparedRow, index: usize) !?[]const u8 {
        if (index >= self.columns.len or index >= self.row.values.len)
            return error.ColumnOutOfRange;
        return self.row.values[index];
    }

    fn typed(self: PreparedRow, index: usize, allowed: []const u8) !bool {
        if ((try self.entry(index)) == null) return false; // NULL stays null
        for (allowed) |typ| if (self.columns[index].type_code == typ) return true;
        return error.ColumnTypeMismatch;
    }

    fn textScanner(self: PreparedRow) text.TextRow {
        return text.TextRow.init(self.row);
    }

    /// Raw bytes are never coerced or interpreted as UTF-8.
    pub fn bytes(self: PreparedRow, index: usize) !?[]const u8 {
        return self.entry(index);
    }

    pub fn string(self: PreparedRow, index: usize) !?[]const u8 {
        if (!try self.typed(index, &.{ 15, 249, 250, 251, 252, 253, 254, 245 }))
            return null;
        return self.textScanner().string(index);
    }

    pub fn int(self: PreparedRow, index: usize) !?i64 {
        if (!try self.typed(index, &.{ 1, 2, 3, 8, 9, 13 })) return null;
        if (self.columns[index].flags & 32 != 0) return error.ColumnTypeMismatch;
        return self.textScanner().int(index);
    }

    pub fn uint(self: PreparedRow, index: usize) !?u64 {
        if (!try self.typed(index, &.{ 1, 2, 3, 8, 9, 13 })) return null;
        if (self.columns[index].flags & 32 == 0) return error.ColumnTypeMismatch;
        return self.textScanner().uint(index);
    }

    pub fn boolean(self: PreparedRow, index: usize) !?bool {
        if (!try self.typed(index, &.{1})) return null;
        return self.textScanner().boolean(index);
    }

    pub fn exactDecimal(self: PreparedRow, index: usize) !?decimal.Decimal {
        if (!try self.typed(index, &.{ 0, 246 })) return null;
        return self.textScanner().exactDecimal(index);
    }

    pub fn date(self: PreparedRow, index: usize) !?temporal.Date {
        if (!try self.typed(index, &.{ 10, 14 })) return null;
        return self.textScanner().date(index);
    }

    /// MySQL TIMESTAMP is exposed in the server's session timezone,
    /// not converted to UTC by this library.
    pub fn dateTime(self: PreparedRow, index: usize) !?temporal.DateTime {
        if (!try self.typed(index, &.{ 7, 12 })) return null;
        return self.textScanner().dateTime(index);
    }

    pub fn time(self: PreparedRow, index: usize) !?temporal.Time {
        if (!try self.typed(index, &.{11})) return null;
        return self.textScanner().time(index);
    }
};

test "prepared scanner: null, signedness, numeric limits and type mismatch" {
    const cols = [_]mysql.Column{
        .{ .name = "signed", .type_code = 8, .flags = 0 },
        .{ .name = "unsigned", .type_code = 8, .flags = 32 },
        .{ .name = "missing", .type_code = 8, .flags = 32 },
        .{ .name = "bad", .type_code = 8, .flags = 0 },
        .{ .name = "blob", .type_code = 252, .flags = 0 },
    };
    const values = [_]?[]const u8{ "-9223372036854775808", "18446744073709551615", null,
        "9223372036854775808", &.{ 0xff, 0, 0xfe } };
    const rows = [_]mysql.Row{.{ .values = &values }};
    const scanner = try PreparedRow.init(.{ .columns = &cols, .items = &rows }, 0);
    try std.testing.expectEqual(std.math.minInt(i64), (try scanner.int(0)).?);
    try std.testing.expectEqual(std.math.maxInt(u64), (try scanner.uint(1)).?);
    try std.testing.expect((try scanner.uint(2)) == null);
    try std.testing.expectError(error.IntegerOverflow, scanner.int(3));
    try std.testing.expectError(error.ColumnTypeMismatch, scanner.int(1));
    try std.testing.expectError(error.ColumnTypeMismatch, scanner.uint(0));
    try std.testing.expectError(error.ColumnTypeMismatch, scanner.date(0));
    try std.testing.expectError(error.InvalidUtf8, scanner.string(4));
    try std.testing.expectEqual(@as(usize, 3), (try scanner.bytes(4)).?.len);
    try std.testing.expectError(error.ColumnOutOfRange, scanner.bytes(5));
    try std.testing.expectError(error.RowOutOfRange, PreparedRow.init(.{ .columns = &cols, .items = &rows }, 1));
}

test "prepared scanner rejects malformed payloads and preserves scalar types" {
    const cols = [_]mysql.Column{
        .{ .name = "decimal", .type_code = 246, .flags = 0 },
        .{ .name = "date", .type_code = 10, .flags = 0 },
        .{ .name = "datetime", .type_code = 12, .flags = 0 },
        .{ .name = "time", .type_code = 11, .flags = 0 },
        .{ .name = "null", .type_code = 6, .flags = 0 },
    };
    const values = [_]?[]const u8{ "123.4500", "2024-02-29", "2024-02-29 11:12:13.000012",
        "-838:59:59", null };
    const rows = [_]mysql.Row{.{ .values = &values }};
    const scanner = try PreparedRow.init(.{ .columns = &cols, .items = &rows }, 0);
    try std.testing.expectEqual(@as(u8, 4), (try scanner.exactDecimal(0)).?.scale);
    try std.testing.expectEqual(@as(u8, 29), (try scanner.date(1)).?.day);
    try std.testing.expectEqual(@as(u32, 12), (try scanner.dateTime(2)).?.microsecond);
    try std.testing.expect((try scanner.time(3)).?.negative);
    try std.testing.expect((try scanner.int(4)) == null);
    const short = [_]mysql.Row{.{ .values = &values[0..1] }};
    try std.testing.expectError(error.ColumnCountMismatch, PreparedRow.init(
        .{ .columns = &cols, .items = &short }, 0));
}
