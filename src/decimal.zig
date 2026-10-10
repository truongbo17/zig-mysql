const std = @import("std");

/// A precision-safe, borrowed MySQL DECIMAL/NEWDECIMAL textual representation.
/// No floating-point conversion, normalization or heap allocation is done.
///
/// The lexer intentionally requires digits on BOTH sides of a decimal point
/// and never accepts exponent notation, NaN, whitespace or binary payloads.
/// MySQL DECIMAL supports at most 65 decimal digits and scale 30; if SQL mode
/// or destination column changes values the server is still authoritative.
/// The caller owns `bytes` (for rows: Result or RowStream owns those bytes).
pub const Decimal = struct {
    bytes: []const u8,
    precision: u8,
    scale: u8,
    negative: bool,

    pub fn parse(bytes: []const u8) !Decimal {
        if (bytes.len == 0) return error.InvalidDecimal;
        var i: usize = 0;
        var negative = false;
        if (bytes[i] == '-' or bytes[i] == '+') {
            negative = bytes[i] == '-';
            i += 1;
        }
        var digits: usize = 0;
        var before: usize = 0;
        var fraction: usize = 0;
        var dot = false;
        while (i < bytes.len) : (i += 1) {
            const ch = bytes[i];
            if (ch == '.') {
                if (dot) return error.InvalidDecimal;
                dot = true;
                continue;
            }
            if (ch < '0' or ch > '9') return error.InvalidDecimal;
            digits += 1;
            if (dot) {
                fraction += 1;
            } else {
                before += 1;
            }
            if (digits > 65 or fraction > 30) return error.DecimalOutOfRange;
        }
        if (before == 0 or (dot and fraction == 0)) return error.InvalidDecimal;
        return .{
            .bytes = bytes,
            .precision = @intCast(digits),
            .scale = @intCast(fraction),
            .negative = negative,
        };
    }
};

test "DECIMAL preserves exact digits and declared scale" {
    const v = try Decimal.parse("-00000000123.450000000000000000000000000000");
    try std.testing.expectEqualStrings("-00000000123.450000000000000000000000000000", v.bytes);
    try std.testing.expectEqual(@as(u8, 30), v.scale);
    try std.testing.expect(v.negative);
    const simple = try Decimal.parse("+0");
    try std.testing.expectEqual(@as(u8, 1), simple.precision);
    try std.testing.expect(!simple.negative);
    const extreme = try Decimal.parse("99999999999999999999999999999999999999999999999999999999999999999");
    try std.testing.expectEqual(@as(u8, 65), extreme.precision);
}

test "DECIMAL rejects malformed or lossy representations" {
    for ([_][]const u8{ "", ".", "-", "1.", ".1", "12.3.4", " 1", "1 ", "1e3", "NaN", "inf", "--2", "0\x00.1" }) |invalid| {
        try std.testing.expectError(error.InvalidDecimal, Decimal.parse(invalid));
    }
    try std.testing.expectError(error.DecimalOutOfRange, Decimal.parse("999999999999999999999999999999999999999999999999999999999999999999"));
    try std.testing.expectError(error.DecimalOutOfRange, Decimal.parse("1.0000000000000000000000000000000"));
}
