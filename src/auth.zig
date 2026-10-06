const std = @import("std");

// MySQL authentication scramble algorithms:
// https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_authentication_methods.html
pub fn nativePassword(password: []const u8, seed: []const u8) [20]u8 {
    if (password.len == 0) return @splat(0);
    var first: [20]u8 = undefined;
    var second: [20]u8 = undefined;
    var challenge: [20]u8 = undefined;
    std.crypto.hash.Sha1.hash(password, &first, .{});
    std.crypto.hash.Sha1.hash(&first, &second, .{});
    var h = std.crypto.hash.Sha1.init(.{});
    h.update(seed);
    h.update(&second);
    h.final(&challenge);
    for (&first, challenge) |*b, c| b.* ^= c;
    return first;
}

pub fn cachingSha2Password(password: []const u8, seed: []const u8) [32]u8 {
    if (password.len == 0) return @splat(0);
    var first: [32]u8 = undefined;
    var second: [32]u8 = undefined;
    var challenge: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(password, &first, .{});
    std.crypto.hash.sha2.Sha256.hash(&first, &second, .{});
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(&second);
    h.update(seed);
    h.final(&challenge);
    for (&first, challenge) |*b, c| b.* ^= c;
    return first;
}

test "native password scramble" {
    const out = nativePassword("secret", "12345678901234567890");
    var expected: [20]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "0f8b9033e0897c0a8338ebe3dea9010dda47ab56");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "caching SHA2 scramble" {
    const out = cachingSha2Password("secret", "12345678901234567890");
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, "51ecd6dedbd34d5445c0a190d4f51acf0d23b94db66c91f3f789faa9193751cd");
    try std.testing.expectEqualSlices(u8, &expected, &out);
}
