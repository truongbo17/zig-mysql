const std = @import("std");

// Classic protocol packet and length-encoded integer formats:
// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html
// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_integer.html
pub const max_packet_payload = 0xff_ff_ff;

pub const Error = error{ Truncated, Malformed, SequenceMismatch, PacketTooLarge };

pub const Cursor = struct {
    bytes: []const u8,
    pos: usize = 0,

    pub fn take(self: *Cursor, n: usize) Error![]const u8 {
        // Reject corrupted cursor state rather than underflowing subtraction.
        if (self.pos > self.bytes.len or n > self.bytes.len - self.pos) return error.Truncated;
        const out = self.bytes[self.pos..][0..n];
        self.pos += n;
        return out;
    }

    pub fn byte(self: *Cursor) Error!u8 {
        return (try self.take(1))[0];
    }

    pub fn uint(self: *Cursor, n: u4) Error!u64 {
        if (n == 0) return error.Malformed;
        const data = try self.take(n);
        var value: u64 = 0;
        for (data, 0..) |b, i| value |= @as(u64, b) << @intCast(i * 8);
        return value;
    }

    pub fn nulString(self: *Cursor) Error![]const u8 {
        if (self.pos > self.bytes.len) return error.Truncated;
        const end = std.mem.indexOfScalarPos(u8, self.bytes, self.pos, 0) orelse return error.Truncated;
        const out = self.bytes[self.pos..end];
        self.pos = end + 1;
        return out;
    }

    pub fn lenInt(self: *Cursor) Error!?u64 {
        const first = try self.byte();
        return switch (first) {
            0xfb => null,
            0xfc => try self.uint(2),
            0xfd => try self.uint(3),
            0xfe => try self.uint(8),
            0xff => error.Malformed,
            else => first,
        };
    }

    pub fn lenString(self: *Cursor) Error!?[]const u8 {
        const n = (try self.lenInt()) orelse return null;
        if (n > std.math.maxInt(usize)) return error.PacketTooLarge;
        return try self.take(@intCast(n));
    }
};

pub const Header = struct {
    length: usize,
    sequence: u8,

    pub fn parse(bytes: []const u8) Error!Header {
        if (bytes.len < 4) return error.Truncated;
        return .{
            .length = @as(usize, bytes[0]) | @as(usize, bytes[1]) << 8 | @as(usize, bytes[2]) << 16,
            .sequence = bytes[3],
        };
    }

    pub fn encode(self: Header) [4]u8 {
        return .{
            @truncate(self.length),
            @truncate(self.length >> 8),
            @truncate(self.length >> 16),
            self.sequence,
        };
    }
};

pub const Handshake = struct {
    server_version: []const u8,
    capabilities: u32,
    charset: u8,
    status: u16,
    seed: [20]u8,
    plugin: []const u8,

    // Protocol::HandshakeV10:
    // https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_packets_protocol_handshake.html
    pub fn parse(bytes: []const u8) Error!Handshake {
        var c = Cursor{ .bytes = bytes };
        if (try c.byte() != 10) return error.Malformed;
        const version = try c.nulString();
        _ = try c.uint(4); // connection id
        const seed1 = try c.take(8);
        _ = try c.byte(); // filler
        const lower: u32 = @intCast(try c.uint(2));
        if (c.pos == bytes.len) return error.Malformed;
        const charset = try c.byte();
        const status: u16 = @intCast(try c.uint(2));
        const upper: u32 = @intCast(try c.uint(2));
        const capabilities = lower | upper << 16;
        const auth_len = try c.byte();
        _ = try c.take(10);
        var seed: [20]u8 = undefined;
        @memcpy(seed[0..8], seed1);
        const part2_len: usize = if (auth_len > 8) @max(@as(usize, auth_len) - 8, 13) else 13;
        const part2 = try c.take(part2_len);
        if (part2.len < 12) return error.Malformed;
        @memcpy(seed[8..20], part2[0..12]);
        const plugin = if (c.pos < bytes.len) try c.nulString() else "mysql_native_password";
        return .{ .server_version = version, .capabilities = capabilities, .charset = charset, .status = status, .seed = seed, .plugin = plugin };
    }
};

test "length encoded integers and null" {
    var c = Cursor{ .bytes = &.{ 250, 0xfb, 0xfc, 0x34, 0x12, 0xfd, 1, 2, 3 } };
    try std.testing.expectEqual(@as(?u64, 250), try c.lenInt());
    try std.testing.expectEqual(@as(?u64, null), try c.lenInt());
    try std.testing.expectEqual(@as(?u64, 0x1234), try c.lenInt());
    try std.testing.expectEqual(@as(?u64, 0x030201), try c.lenInt());
    try std.testing.expectError(error.Truncated, c.lenInt());
}

test "packet header roundtrip" {
    const header = Header{ .length = max_packet_payload, .sequence = 255 };
    try std.testing.expectEqualDeep(header, try Header.parse(&header.encode()));
    try std.testing.expectError(error.Truncated, Header.parse(&.{ 1, 2, 3 }));
}

test "cursor rejects malformed lengths" {
    var c = Cursor{ .bytes = &.{0xff} };
    try std.testing.expectError(error.Malformed, c.lenInt());
    var d = Cursor{ .bytes = &.{ 4, 'a' } };
    try std.testing.expectError(error.Truncated, d.lenString());
}

test "cursor corrupted offset and truncated length-encoded payload" {
    var invalid = Cursor{ .bytes = &.{ 1, 2, 3 }, .pos = 4 };
    try std.testing.expectError(error.Truncated, invalid.take(1));
    try std.testing.expectError(error.Truncated, invalid.nulString());
    var text = Cursor{ .bytes = &.{ 0xfc, 0xff, 0xff, 'x' } };
    try std.testing.expectError(error.Truncated, text.lenString());
    var partial = Cursor{ .bytes = &.{ 0xfe, 1, 2, 3 } };
    try std.testing.expectError(error.Truncated, partial.lenInt());
}
