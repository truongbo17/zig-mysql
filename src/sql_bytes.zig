const std = @import("std");

/// Explicit, zero-copy view over an existing byte buffer. Neither text nor
/// JSON validation grants ownership or changes the original bytes. A view
/// over RowStream.next expires on next/deinit; a buffered Result view expires
/// on Result.deinit. For long-lived data, copy using a caller-owned allocator.
pub const SqlBytes = struct {
    bytes: []const u8,
    kind: Kind,

    pub const Kind = enum { blob, utf8, json };

    /// Preserve all bytes including NUL and invalid UTF-8 for binary columns.
    pub fn blob(raw: []const u8) SqlBytes {
        return .{ .bytes = raw, .kind = .blob };
    }

    /// Validate UTF-8 without allocating, decoding or normalizing text.
    pub fn text(raw: []const u8) !SqlBytes {
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
        return .{ .bytes = raw, .kind = .utf8 };
    }

    /// Validate JSON structure with temporary allocations; returned view
    /// borrows raw input, not the temporary std.json parsed tree.
    /// MySQL JSON columns may canonicalize documents when stored on server.
    pub fn json(allocator: std.mem.Allocator, raw: []const u8) !SqlBytes {
        if (!std.unicode.utf8ValidateSlice(raw)) return error.InvalidUtf8;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch |err| {
            if (err == error.OutOfMemory) return err;
            return error.InvalidJson;
        };
        parsed.deinit();
        return .{ .bytes = raw, .kind = .json };
    }
};

test "BLOB view preserves arbitrary bytes, embedded NUL and invalid UTF8" {
    const raw = &[_]u8{ 0x00, 0xff, 0xfe, 0x61, 0x00, 0x80 };
    const binary = SqlBytes.blob(raw);
    try std.testing.expectEqual(SqlBytes.Kind.blob, binary.kind);
    try std.testing.expectEqualSlices(u8, raw, binary.bytes);
    try std.testing.expectError(error.InvalidUtf8, SqlBytes.text(raw));
    try std.testing.expectError(error.InvalidUtf8, SqlBytes.json(std.testing.allocator, raw));
}

test "UTF8 and JSON validation never rewrites original bytes" {
    const input = "{\"chào\":\"Việt Nam\",\"count\":12,\"ok\":true}";
    const json = try SqlBytes.json(std.testing.allocator, input);
    try std.testing.expectEqual(SqlBytes.Kind.json, json.kind);
    try std.testing.expectEqualStrings(input, json.bytes);
    const utf8 = try SqlBytes.text("Tiếng Việt\x00hello");
    try std.testing.expectEqualStrings("Tiếng Việt\x00hello", utf8.bytes);
    try std.testing.expectError(error.InvalidJson, SqlBytes.json(std.testing.allocator, "{\"a\":"));
    try std.testing.expectError(error.InvalidJson, SqlBytes.json(std.testing.allocator, "not json"));
}

test "JSON scalar and empty BLOB are explicit and valid" {
    const scalar = try SqlBytes.json(std.testing.allocator, "123");
    try std.testing.expectEqualStrings("123", scalar.bytes);
    const empty = SqlBytes.blob("");
    try std.testing.expectEqual(@as(usize, 0), empty.bytes.len);
}
