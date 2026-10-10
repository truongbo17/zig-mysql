const std = @import("std");
const client = @import("client.zig");
const decimal = @import("decimal.zig");
const temporal = @import("temporal.zig");

/// Explicit, allocation-free conversions of a text-protocol row.
/// Returned slices / Decimal.bytes borrow the row memory:
/// - buffered Result: until Result.deinit()
/// - RowStream: until the next next()/nextWithTimeout()/deinit().
/// NULL is always represented as null, never converted to zero or empty.
pub const TextRow = struct {
    row: client.Row,

    pub fn init(row: client.Row) TextRow {
        return .{ .row = row };
    }

    pub fn raw(self: TextRow, index: usize) !?[]const u8 {
        if (index >= self.row.values.len) return error.ColumnOutOfRange;
        return self.row.values[index];
    }

    pub fn bytes(self: TextRow, index: usize) !?[]const u8 {
        return self.raw(index);
    }

    pub fn string(self: TextRow, index: usize) !?[]const u8 {
        const value = (try self.raw(index)) orelse return null;
        if (!std.unicode.utf8ValidateSlice(value)) return error.InvalidUtf8;
        return value;
    }

    pub fn int(self: TextRow, index: usize) !?i64 {
        const value = (try self.raw(index)) orelse return null;
        // MySQL sends ASCII decimal integers. Do not accept +, spaces or
        // prefixes; parseInt catches both malformed input and overflow.
        if (value.len == 0) return error.InvalidInteger;
        var start: usize = 0;
        if (value[0] == '-') start = 1;
        if (start == value.len) return error.InvalidInteger;
        for (value[start..]) |ch| {
            if (ch < '0' or ch > '9') return error.InvalidInteger;
        }
        return std.fmt.parseInt(i64, value, 10) catch |err| switch (err) {
            error.Overflow => error.IntegerOverflow,
            else => error.InvalidInteger,
        };
    }

    pub fn uint(self: TextRow, index: usize) !?u64 {
        const value = (try self.raw(index)) orelse return null;
        if (value.len == 0) return error.InvalidInteger;
        for (value) |ch| {
            if (ch < '0' or ch > '9') return error.InvalidInteger;
        }
        return std.fmt.parseInt(u64, value, 10) catch |err| switch (err) {
            error.Overflow => error.IntegerOverflow,
            else => error.InvalidInteger,
        };
    }

    pub fn boolean(self: TextRow, index: usize) !?bool {
        const value = (try self.raw(index)) orelse return null;
        if (std.mem.eql(u8, value, "0")) return false;
        if (std.mem.eql(u8, value, "1")) return true;
        return error.InvalidBoolean;
    }

    pub fn exactDecimal(self: TextRow, index: usize) !?decimal.Decimal {
        const value = (try self.raw(index)) orelse return null;
        return try decimal.Decimal.parse(value);
    }

    pub fn date(self: TextRow, index: usize) !?temporal.Date {
        const value = (try self.raw(index)) orelse return null;
        return try temporal.parseDate(value);
    }

    pub fn dateTime(self: TextRow, index: usize) !?temporal.DateTime {
        const value = (try self.raw(index)) orelse return null;
        return try temporal.parseDateTime(value);
    }

    pub fn time(self: TextRow, index: usize) !?temporal.Time {
        const value = (try self.raw(index)) orelse return null;
        return try temporal.parseTime(value);
    }
};

test "typed text scanner preserves NULL, binary bytes and UTF-8" {
    const values = [_]?[]const u8{ null, "", "Xin chào Việt Nam", &.{ 0, 0xff, 12 }, "1" };
    const scan = TextRow.init(.{ .values = &values });
    try std.testing.expect((try scan.string(0)) == null);
    try std.testing.expectEqualStrings("", (try scan.string(1)).?);
    try std.testing.expectEqualStrings("Xin chào Việt Nam", (try scan.string(2)).?);
    try std.testing.expectEqual(@as(usize, 3), (try scan.bytes(3)).?.len);
    try std.testing.expectError(error.InvalidUtf8, scan.string(3));
    try std.testing.expectEqual(true, (try scan.boolean(4)).?);
    try std.testing.expectError(error.ColumnOutOfRange, scan.raw(5));
}

test "typed text scanner detects integer overflow and bad numeric coercions" {
    const values = [_]?[]const u8{
        "-9223372036854775808", "9223372036854775807", "9223372036854775808",
        "18446744073709551615", "18446744073709551616", "-1", " 12", "+1", "01", "", "2",
    };
    const scan = TextRow.init(.{ .values = &values });
    try std.testing.expectEqual(std.math.minInt(i64), (try scan.int(0)).?);
    try std.testing.expectEqual(std.math.maxInt(i64), (try scan.int(1)).?);
    try std.testing.expectError(error.IntegerOverflow, scan.int(2));
    try std.testing.expectEqual(std.math.maxInt(u64), (try scan.uint(3)).?);
    try std.testing.expectError(error.IntegerOverflow, scan.uint(4));
    try std.testing.expectError(error.InvalidInteger, scan.uint(5));
    try std.testing.expectError(error.InvalidInteger, scan.int(6));
    try std.testing.expectError(error.InvalidInteger, scan.int(7));
    try std.testing.expectEqual(@as(i64, 1), (try scan.int(8)).?);
    try std.testing.expectError(error.InvalidInteger, scan.int(9));
    try std.testing.expectError(error.InvalidBoolean, scan.boolean(10));
}

test "typed text scanner lossless DECIMAL and temporal" {
    const values = [_]?[]const u8{ "-999999999999.00010", "2024-02-29", "2024-02-29 12:59:58.123456", "-838:59:59", "0000-00-00" };
    const scan = TextRow.init(.{ .values = &values });
    const exact = (try scan.exactDecimal(0)).?;
    try std.testing.expectEqualStrings("-999999999999.00010", exact.bytes);
    try std.testing.expectEqual(@as(u8, 5), exact.scale);
    try std.testing.expectEqual(@as(u8, 29), (try scan.date(1)).?.day);
    try std.testing.expectEqual(@as(u32, 123456), (try scan.dateTime(2)).?.microsecond);
    try std.testing.expect((try scan.time(3)).?.negative);
    try std.testing.expectError(error.ZeroDate, scan.date(4));
}
