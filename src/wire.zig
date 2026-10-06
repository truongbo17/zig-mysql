const std = @import("std");
const protocol = @import("protocol.zig");

/// One classic-protocol exchange. The sequence resets before each command.
pub const Wire = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    sequence: u8 = 0,
    max_message_size: usize = 64 * 1024 * 1024,

    pub fn reset(self: *Wire) void {
        self.sequence = 0;
    }

    pub fn read(self: *Wire, io: std.Io) ![]u8 {
        var message: std.ArrayList(u8) = .empty;
        errdefer message.deinit(self.allocator);
        while (true) {
            var header_bytes: [4]u8 = undefined;
            try self.readExact(io, &header_bytes);
            const header = try protocol.Header.parse(&header_bytes);
            if (header.sequence != self.sequence) return error.SequenceMismatch;
            self.sequence +%= 1;
            if (header.length > self.max_message_size -| message.items.len) return error.PacketTooLarge;
            const old_len = message.items.len;
            try message.resize(self.allocator, old_len + header.length);
            try self.readExact(io, message.items[old_len..]);
            if (header.length < protocol.max_packet_payload) break;
        }
        return try message.toOwnedSlice(self.allocator);
    }

    pub fn write(self: *Wire, io: std.Io, payload: []const u8) !void {
        var remaining = payload;
        while (true) {
            const n = @min(remaining.len, protocol.max_packet_payload);
            const header = (protocol.Header{ .length = n, .sequence = self.sequence }).encode();
            try self.writeAll(io, &header);
            try self.writeAll(io, remaining[0..n]);
            self.sequence +%= 1;
            remaining = remaining[n..];
            if (n < protocol.max_packet_payload) break;
        }
    }

    fn readExact(self: *Wire, io: std.Io, destination: []u8) !void {
        var used: usize = 0;
        while (used < destination.len) {
            var buffers: [1][]u8 = .{destination[used..]};
            const result = try self.stream.readWithControl(io, &buffers, &.{});
            if (result.data_len == 0) return error.EndOfStream;
            used += result.data_len;
        }
    }

    fn writeAll(self: *Wire, io: std.Io, bytes: []const u8) !void {
        var remaining = bytes;
        while (remaining.len > 0) {
            const result = try io.operate(.{ .net_write = .{
                .socket_handle = self.stream.socket.handle,
                .data = &.{remaining},
            } });
            const n = try result.net_write;
            if (n == 0) return error.WriteZero;
            remaining = remaining[n..];
        }
    }
};
