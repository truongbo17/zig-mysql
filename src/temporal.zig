const std = @import("std");

/// Strict borrowed-value temporal decoders for MySQL text or prepared
/// binary result values. These types do NOT infer or adjust a timezone.
/// In particular, TIMESTAMP is converted to session timezone by MySQL.
pub const Date = struct {
    year: u16,
    month: u8,
    day: u8,
};

pub const DateTime = struct {
    date: Date,
    hour: u8,
    minute: u8,
    second: u8,
    microsecond: u32 = 0,
    fractional_digits: u8 = 0,
};

/// MySQL TIME is a signed DURATION, not a time-of-day. Hours can exceed 23.
pub const Time = struct {
    negative: bool,
    hours: u16,
    minutes: u8,
    seconds: u8,
    microsecond: u32 = 0,
    fractional_digits: u8 = 0,
};

fn digits(input: []const u8) !u32 {
    if (input.len == 0) return error.InvalidTemporal;
    var value: u32 = 0;
    for (input) |c| {
        if (c < '0' or c > '9') return error.InvalidTemporal;
        value = value * 10 + (c - '0');
    }
    return value;
}

fn leap(year: u16) bool {
    return @mod(year, 4) == 0 and (@mod(year, 100) != 0 or @mod(year, 400) == 0);
}

pub fn parseDate(raw: []const u8) !Date {
    if (raw.len != 10 or raw[4] != '-' or raw[7] != '-')
        return error.InvalidTemporal;
    const year: u16 = @intCast(try digits(raw[0..4]));
    const month: u8 = @intCast(try digits(raw[5..7]));
    const day: u8 = @intCast(try digits(raw[8..10]));
    if (year == 0 or month == 0 or day == 0) return error.ZeroDate;
    if (month > 12) return error.InvalidTemporal;
    const max_day: u8 = switch (month) {
        2 => if (leap(year)) 29 else 28,
        4, 6, 9, 11 => 30,
        else => 31,
    };
    if (day > max_day) return error.InvalidTemporal;
    return .{ .year = year, .month = month, .day = day };
}

fn fractional(raw: []const u8) !struct { value: u32, digits_count: u8 } {
    if (raw.len == 0) return .{ .value = 0, .digits_count = 0 };
    if (raw[0] != '.' or raw.len < 2 or raw.len > 7) return error.InvalidTemporal;
    const count: u8 = @intCast(raw.len - 1);
    var value = try digits(raw[1..]);
    for (count..6) |_| value *= 10;
    return .{ .value = value, .digits_count = count };
}

pub fn parseDateTime(raw: []const u8) !DateTime {
    if (raw.len < 19 or raw[10] != ' ' or raw[13] != ':' or raw[16] != ':')
        return error.InvalidTemporal;
    const date = try parseDate(raw[0..10]);
    const hour: u8 = @intCast(try digits(raw[11..13]));
    const minute: u8 = @intCast(try digits(raw[14..16]));
    const second: u8 = @intCast(try digits(raw[17..19]));
    if (hour > 23 or minute > 59 or second > 59) return error.InvalidTemporal;
    const frac = try fractional(raw[19..]);
    return .{ .date = date, .hour = hour, .minute = minute, .second = second,
        .microsecond = frac.value, .fractional_digits = frac.digits_count };
}

pub fn parseTime(raw: []const u8) !Time {
    if (raw.len == 0) return error.InvalidTemporal;
    const negative = raw[0] == '-';
    const start: usize = if (negative) 1 else 0;
    const first_colon = std.mem.indexOfScalarPos(u8, raw, start, ':') orelse return error.InvalidTemporal;
    if (first_colon - start < 2 or first_colon - start > 3)
        return error.InvalidTemporal;
    const suffix = raw[first_colon + 1 ..];
    if (suffix.len < 5 or suffix[2] != ':') return error.InvalidTemporal;
    const hours: u16 = @intCast(try digits(raw[start..first_colon]));
    const minute: u8 = @intCast(try digits(suffix[0..2]));
    const second: u8 = @intCast(try digits(suffix[3..5]));
    if (hours > 838 or minute > 59 or second > 59) return error.InvalidTemporal;
    const frac = try fractional(suffix[5..]);
    // MySQL TIME range is [-838:59:59, +838:59:59]; a nonzero
    // fraction at either extreme crosses the documented bound.
    if (hours == 838 and minute == 59 and second == 59 and frac.value != 0)
        return error.InvalidTemporal;
    return .{ .negative = negative, .hours = hours,
        .minutes = minute, .seconds = second, .microsecond = frac.value,
        .fractional_digits = frac.digits_count };
}

test "strict Gregorian date, leap day, explicit zero-date policy" {
    const value = try parseDate("2024-02-29");
    try std.testing.expectEqual(@as(u16, 2024), value.year);
    try std.testing.expectEqual(@as(u8, 29), value.day);
    try std.testing.expectError(error.InvalidTemporal, parseDate("2023-02-29"));
    try std.testing.expectError(error.InvalidTemporal, parseDate("1900-02-29"));
    _ = try parseDate("2000-02-29");
    try std.testing.expectError(error.InvalidTemporal, parseDate("2024-13-01"));
    try std.testing.expectError(error.InvalidTemporal, parseDate("2024-04-31"));
    try std.testing.expectError(error.ZeroDate, parseDate("0000-00-00"));
    try std.testing.expectError(error.ZeroDate, parseDate("2024-00-01"));
    try std.testing.expectError(error.InvalidTemporal, parseDate("2024-0x-01"));
}

test "DATETIME keeps six-digit microseconds without applying timezone" {
    const stamp = try parseDateTime("2024-02-29 23:59:59.000012");
    try std.testing.expectEqual(@as(u32, 12), stamp.microsecond);
    try std.testing.expectEqual(@as(u8, 6), stamp.fractional_digits);
    try std.testing.expectEqual(@as(u8, 23), stamp.hour);
    const short = try parseDateTime("2024-02-29 03:04:05.1");
    try std.testing.expectEqual(@as(u32, 100000), short.microsecond);
    try std.testing.expectEqual(@as(u8, 1), short.fractional_digits);
    try std.testing.expectError(error.InvalidTemporal, parseDateTime("2024-02-29 24:00:00"));
    try std.testing.expectError(error.InvalidTemporal, parseDateTime("2024-02-29 00:00:00."));
    try std.testing.expectError(error.InvalidTemporal, parseDateTime("2024-02-29T00:00:00"));
}

test "MySQL signed duration TIME supports 838h with micros" {
    const time = try parseTime("-838:59:59");
    try std.testing.expect(time.negative);
    try std.testing.expectEqual(@as(u16, 838), time.hours);
    try std.testing.expectEqual(@as(u32, 0), time.microsecond);
    try std.testing.expectError(error.InvalidTemporal, parseTime("-838:59:59.000001"));
    try std.testing.expectError(error.InvalidTemporal, parseTime("838:59:59.999999"));
    const small = try parseTime("00:00:01.04");
    try std.testing.expectEqual(@as(u32, 40000), small.microsecond);
    try std.testing.expectError(error.InvalidTemporal, parseTime("839:00:00"));
    try std.testing.expectError(error.InvalidTemporal, parseTime("01:60:00"));
    try std.testing.expectError(error.InvalidTemporal, parseTime("00:00:00.1234567"));
    try std.testing.expectError(error.InvalidTemporal, parseTime("garbage"));
}
