const std = @import("std");
const mysql = @import("zig_mysql");

test "silent server greeting is bounded by connectWithTimeout" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(error.ConnectTimeout, mysql.Client.connectWithTimeout(
        std.testing.allocator, io, .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33309") },
            .username = "test",
            .password = "test",
        }, .fromMilliseconds(100),
    ));
}

test "stalled nonblocking TLS ServerHello is bounded by connectWithTimeout" {
    var threaded: std.Io.Threaded = .init(std.testing.allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    try std.testing.expectError(error.ConnectTimeout, mysql.Client.connectWithTimeout(
        std.testing.allocator, io, .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33310") },
            .username = "test",
            .password = "test",
            .tls = .{ .host = "localhost" },
        }, .fromMilliseconds(100),
    ));
}
