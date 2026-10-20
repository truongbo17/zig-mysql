const std = @import("std");

pub fn main(init: std.process.Init) !void {
    // Compare std.process.Init.io automatic teardown against explicit
    // std.Io.Threaded ownership; all driver/TLS/pool operations unchanged.
    _ = init;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer {
        std.debug.print("D3_THREADED_DEINIT_BEGIN\n", .{});
        threaded.deinit();
        std.debug.print("D3_THREADED_DEINIT_END\n", .{});
    }
    try @import("high_ccu_tls_checked.zig").runChecked(threaded.io(), true);
    std.debug.print("D3_THREADED_WORKLOAD_RETURNED\n", .{});
}
