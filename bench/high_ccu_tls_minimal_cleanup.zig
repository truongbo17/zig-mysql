// std.process.Init.Minimal avoids implicitly creating the process-owned Io runtime.
// Benchmark-only controlled native shutdown comparison for #65.
const std = @import("std");
extern "crypto" fn OPENSSL_cleanup() void;

pub fn main(_: std.process.Init.Minimal) !void {
    // Compare std.process.Init.io automatic teardown against explicit
    // std.Io.Threaded ownership; all driver/TLS/pool operations unchanged.
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer {
        std.debug.print("D3_CLEANUP_DEINIT_BEGIN\n", .{});
        threaded.deinit();
        std.debug.print("D3_CLEANUP_DEINIT_END\n", .{});
        std.debug.print("D3_OPENSSL_CLEANUP_BEGIN\\n", .{});
        OPENSSL_cleanup();
        std.debug.print("D3_OPENSSL_CLEANUP_END\\n", .{});
    }
    try @import("high_ccu_tls_checked.zig").runChecked(threaded.io(), true);
    std.debug.print("D3_CLEANUP_WORKLOAD_RETURNED\n", .{});
}
