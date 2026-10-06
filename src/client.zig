const std = @import("std");
const protocol = @import("protocol.zig");
const auth = @import("auth.zig");
const Wire = @import("wire.zig").Wire;

const client_protocol_41: u32 = 1 << 9;
const client_connect_with_db: u32 = 1 << 3;
const client_transactions: u32 = 1 << 13;
const client_secure_connection: u32 = 1 << 15;
const client_plugin_auth: u32 = 1 << 19;

pub const Config = struct {
    address: std.Io.net.IpAddress,
    username: []const u8,
    password: []const u8,
    database: []const u8 = "",
    max_message_size: usize = 64 * 1024 * 1024,
};

pub const ServerError = struct {
    code: u16,
    sql_state: [5]u8,
    message: []const u8,
};

pub const Ok = struct {
    affected_rows: u64,
    last_insert_id: u64,
    status: u16,
    warnings: u16,
};

pub const Column = struct {
    name: []const u8,
    type_code: u8,
    flags: u16,
};

pub const Row = struct {
    values: []const ?[]const u8,
};

pub const Rows = struct {
    columns: []const Column,
    items: []const Row,
};

/// The returned result owns all text and row memory. Call deinit after use.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: union(enum) { ok: Ok, rows: Rows },

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    wire: Wire,
    last_server_error: ?ServerError = null,

    /// Opens a classic-protocol TCP connection and authenticates.
    /// This first transport supports native auth and cached SHA2 fast auth.
    /// Full SHA2 auth over unencrypted TCP is rejected.
    pub fn connect(allocator: std.mem.Allocator, io: std.Io, config: Config) !Client {
        const stream = try config.address.connect(io, .{ .mode = .stream });
        var self = Client{ .allocator = allocator, .wire = .{
            .allocator = allocator,
            .stream = stream,
            .max_message_size = config.max_message_size,
        } };
        errdefer self.deinit(io);

        const greeting = try self.wire.read(io);
        defer allocator.free(greeting);
        if (greeting.len > 0 and greeting[0] == 0xff) return self.serverFailure(greeting);
        const hello = try protocol.Handshake.parse(greeting);
        const required = client_protocol_41 | client_secure_connection | client_plugin_auth;
        if (hello.capabilities & required != required) return error.UnsupportedServer;

        const flags = (required | client_transactions |
            (if (config.database.len > 0) client_connect_with_db else @as(u32, 0))) & hello.capabilities;
        var response: std.ArrayList(u8) = .empty;
        defer response.deinit(allocator);
        try appendInt(&response, allocator, flags, 4);
        try appendInt(&response, allocator, @min(config.max_message_size, std.math.maxInt(u32)), 4);
        try response.append(allocator, 45); // utf8mb4_general_ci
        try response.appendNTimes(allocator, 0, 23);
        try appendNul(&response, allocator, config.username);
        try appendAuth(&response, allocator, hello.plugin, config.password, &hello.seed);
        if (config.database.len > 0) try appendNul(&response, allocator, config.database);
        try appendNul(&response, allocator, hello.plugin);
        try self.wire.write(io, response.items);
        try self.finishAuthentication(io, config.password, hello.plugin, &hello.seed);
        return self;
    }

    pub fn deinit(self: *Client, io: std.Io) void {
        if (self.last_server_error) |e| self.allocator.free(e.message);
        self.wire.stream.close(io);
    }

    pub fn ping(self: *Client, io: std.Io) !void {
        try self.command(io, 0x0e, "");
        const packet = try self.wire.read(io);
        defer self.allocator.free(packet);
        if (packet.len == 0) return error.Malformed;
        if (packet[0] == 0xff) return self.serverFailure(packet);
        if (packet[0] != 0x00) return error.Malformed;
    }

    pub fn query(self: *Client, io: std.Io, sql: []const u8) !Result {
        try self.command(io, 0x03, sql);
        const first = try self.wire.read(io);
        defer self.allocator.free(first);
        if (first.len == 0) return error.Malformed;
        if (first[0] == 0xff) return self.serverFailure(first);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        if (first[0] == 0x00) {
            return .{ .arena = arena, .value = .{ .ok = try parseOk(first) } };
        }
        if (first[0] == 0xfb) return error.LocalInfileDisabled;
        var counter = protocol.Cursor{ .bytes = first };
        const n64 = (try counter.lenInt()) orelse return error.Malformed;
        if (n64 == 0 or n64 > 4096) return error.Malformed;
        const n: usize = @intCast(n64);
        const a = arena.allocator();
        const columns = try a.alloc(Column, n);
        for (columns) |*column| {
            const packet = try self.wire.read(io);
            defer self.allocator.free(packet);
            if (packet.len > 0 and packet[0] == 0xff) return self.serverFailure(packet);
            column.* = try parseColumn(a, packet);
        }
        const metadata_end = try self.wire.read(io);
        defer self.allocator.free(metadata_end);
        if (!isEof(metadata_end)) return error.Malformed;
        var rows: std.ArrayList(Row) = .empty;
        while (true) {
            const packet = try self.wire.read(io);
            defer self.allocator.free(packet);
            if (packet.len > 0 and packet[0] == 0xff) return self.serverFailure(packet);
            if (isEof(packet)) break;
            var c = protocol.Cursor{ .bytes = packet };
            const values = try a.alloc(?[]const u8, n);
            for (values) |*value| {
                const bytes = try c.lenString();
                value.* = if (bytes) |b| try a.dupe(u8, b) else null;
            }
            if (c.pos != packet.len) return error.Malformed;
            try rows.append(a, .{ .values = values });
        }
        return .{ .arena = arena, .value = .{ .rows = .{
            .columns = columns,
            .items = try rows.toOwnedSlice(a),
        } } };
    }

    fn command(self: *Client, io: std.Io, code: u8, data: []const u8) !void {
        self.wire.reset();
        const payload = try self.allocator.alloc(u8, data.len + 1);
        defer self.allocator.free(payload);
        payload[0] = code;
        @memcpy(payload[1..], data);
        try self.wire.write(io, payload);
    }

    fn finishAuthentication(self: *Client, io: std.Io, password: []const u8, initial_plugin: []const u8, initial_seed: []const u8) !void {
        var plugin = initial_plugin;
        var seed = initial_seed;
        var plugin_storage: [128]u8 = undefined;
        var seed_storage: [128]u8 = undefined;
        var exchanges: usize = 0;
        while (exchanges < 8) : (exchanges += 1) {
            const packet = try self.wire.read(io);
            defer self.allocator.free(packet);
            if (packet.len == 0) return error.Malformed;
            switch (packet[0]) {
                0x00 => return,
                0xff => return self.serverFailure(packet),
                0xfe => {
                    var c = protocol.Cursor{ .bytes = packet[1..] };
                    const next_plugin = try c.nulString();
                    const next_seed = std.mem.trimEnd(u8, packet[1 + c.pos ..], "\x00");
                    if (next_plugin.len > plugin_storage.len or next_seed.len > seed_storage.len) return error.Malformed;
                    @memcpy(plugin_storage[0..next_plugin.len], next_plugin);
                    @memcpy(seed_storage[0..next_seed.len], next_seed);
                    plugin = plugin_storage[0..next_plugin.len];
                    seed = seed_storage[0..next_seed.len];
                    const reply = try authResponse(self.allocator, plugin, password, seed);
                    defer self.allocator.free(reply);
                    try self.wire.write(io, reply);
                },
                0x01 => {
                    if (!std.mem.eql(u8, plugin, "caching_sha2_password") or packet.len < 2) return error.UnsupportedAuthentication;
                    switch (packet[1]) {
                        0x03 => {}, // fast auth succeeded; final OK follows
                        0x04 => return error.SecureTransportRequired,
                        else => return error.UnsupportedAuthentication,
                    }
                },
                else => return error.Malformed,
            }
        }
        return error.TooManyAuthenticationExchanges;
    }

    fn serverFailure(self: *Client, packet: []const u8) anyerror {
        if (self.last_server_error) |e| self.allocator.free(e.message);
        var state: [5]u8 = "HY000".*;
        if (packet.len >= 9 and packet[3] == '#') @memcpy(&state, packet[4..9]);
        const start: usize = if (packet.len >= 9 and packet[3] == '#') 9 else 3;
        self.last_server_error = .{
            .code = if (packet.len >= 3) @as(u16, packet[1]) | @as(u16, packet[2]) << 8 else 0,
            .sql_state = state,
            .message = self.allocator.dupe(u8, if (packet.len >= start) packet[start..] else "") catch return error.OutOfMemory,
        };
        return error.ServerError;
    }
};

fn authResponse(allocator: std.mem.Allocator, plugin: []const u8, password: []const u8, seed: []const u8) ![]u8 {
    if (password.len == 0) return allocator.alloc(u8, 0);
    if (std.mem.eql(u8, plugin, "mysql_native_password")) {
        return allocator.dupe(u8, &auth.nativePassword(password, seed));
    }
    if (std.mem.eql(u8, plugin, "caching_sha2_password")) {
        return allocator.dupe(u8, &auth.cachingSha2Password(password, seed));
    }
    return error.UnsupportedAuthentication;
}

fn appendAuth(out: *std.ArrayList(u8), allocator: std.mem.Allocator, plugin: []const u8, password: []const u8, seed: []const u8) !void {
    const response = try authResponse(allocator, plugin, password, seed);
    defer allocator.free(response);
    try out.append(allocator, @intCast(response.len));
    try out.appendSlice(allocator, response);
}

fn appendNul(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidConfiguration;
    try out.appendSlice(allocator, text);
    try out.append(allocator, 0);
}

fn appendInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, number: u64, count: usize) !void {
    for (0..count) |i| try out.append(allocator, @truncate(number >> @intCast(i * 8)));
}

fn isEof(packet: []const u8) bool {
    return packet.len > 0 and packet.len < 9 and packet[0] == 0xfe;
}

fn parseOk(packet: []const u8) !Ok {
    var c = protocol.Cursor{ .bytes = packet };
    if (try c.byte() != 0) return error.Malformed;
    const affected = (try c.lenInt()) orelse return error.Malformed;
    const insert_id = (try c.lenInt()) orelse return error.Malformed;
    return .{
        .affected_rows = affected,
        .last_insert_id = insert_id,
        .status = @intCast(try c.uint(2)),
        .warnings = @intCast(try c.uint(2)),
    };
}

fn parseColumn(allocator: std.mem.Allocator, packet: []const u8) !Column {
    var c = protocol.Cursor{ .bytes = packet };
    for (0..4) |_| _ = (try c.lenString()) orelse return error.Malformed;
    const name = (try c.lenString()) orelse return error.Malformed;
    _ = (try c.lenString()) orelse return error.Malformed;
    if (try c.byte() != 0x0c) return error.Malformed;
    _ = try c.uint(2); // charset
    _ = try c.uint(4); // maximum column length
    const type_code = try c.byte();
    const flags: u16 = @intCast(try c.uint(2));
    return .{ .name = try allocator.dupe(u8, name), .type_code = type_code, .flags = flags };
}

test "parse OK packet and column metadata" {
    const ok = try parseOk(&.{ 0, 2, 7, 2, 0, 0, 0 });
    try std.testing.expectEqual(@as(u64, 2), ok.affected_rows);
    try std.testing.expectEqual(@as(u64, 7), ok.last_insert_id);
    const col = try parseColumn(std.testing.allocator, &.{ 3, 'd', 'e', 'f', 0, 0, 0, 2, 'i', 'd', 2, 'i', 'd', 12, 45, 0, 11, 0, 0, 0, 3, 0, 0, 0, 0 });
    defer std.testing.allocator.free(col.name);
    try std.testing.expectEqualStrings("id", col.name);
}
