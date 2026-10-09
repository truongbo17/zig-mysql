const std = @import("std");
const protocol = @import("protocol.zig");
const tls_backend = @import("openssl.zig");

/// One classic-protocol exchange. The sequence resets before each command.
pub const Wire = struct {
    allocator: std.mem.Allocator,
    stream: std.Io.net.Stream,
    tls: ?tls_backend.Session = null,
    sequence: u8 = 0,
    max_message_size: usize = 64 * 1024 * 1024,

    pub fn reset(self: *Wire) void {
        self.sequence = 0;
    }

    pub fn close(self: *Wire, io: std.Io) void {
        if (self.tls) |*session| session.deinit();
        self.stream.close(io);
    }

    /// Starts a verified TLS session after the MySQL SSLRequest packet.
    pub fn startTls(self: *Wire, io: std.Io, host: []const u8, ca_file: ?[]const u8) !void {
        if (self.tls != null) return error.AlreadyEncrypted;
        self.tls = try tls_backend.Session.init(self.allocator, io, @intCast(self.stream.socket.handle), host, ca_file);
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
            if (n <= 4092) {
                // A single small write avoids a TCP delayed-ACK/Nagle stall
                // between the four-byte header and the command payload.
                // Keep the common MySQL command path allocation-free.
                var packet: [4096]u8 = undefined;
                @memcpy(packet[0..4], &header);
                @memcpy(packet[4..][0..n], remaining[0..n]);
                try self.writeAll(io, packet[0 .. n + 4]);
            } else {
                // Avoid copying 16-MiB payloads just to combine a header.
                try self.writeAll(io, &header);
                try self.writeAll(io, remaining[0..n]);
            }
            self.sequence +%= 1;
            remaining = remaining[n..];
            if (n < protocol.max_packet_payload) break;
        }
    }

    fn readExact(self: *Wire, io: std.Io, destination: []u8) !void {
        if (self.tls) |*session| {
            try session.readExact(io, destination);
            return;
        }
        var used: usize = 0;
        while (used < destination.len) {
            var buffers: [1][]u8 = .{destination[used..]};
            const n = if (comptime @hasDecl(std.Io.net.Stream, "readWithControl")) blk: {
                const result = try self.stream.readWithControl(io, &buffers, &.{});
                break :blk result.data_len;
            } else try io.vtable.netRead(io.userdata, self.stream.socket.handle, &buffers);
            if (n == 0) return error.EndOfStream;
            used += n;
        }
    }

    fn writeAll(self: *Wire, io: std.Io, bytes: []const u8) !void {
        if (self.tls) |*session| {
            try session.writeAll(io, bytes);
            return;
        }
        var remaining = bytes;
        while (remaining.len > 0) {
            const n = if (comptime @hasField(std.Io.Operation, "net_write")) blk: {
                const result = try io.operate(.{ .net_write = .{
                    .socket_handle = self.stream.socket.handle,
                    .data = &.{remaining},
                } });
                break :blk try result.net_write;
            } else try io.vtable.netWrite(io.userdata, self.stream.socket.handle, &.{}, &.{remaining}, 1);
            if (n == 0) return error.WriteZero;
            remaining = remaining[n..];
        }
    }
};
