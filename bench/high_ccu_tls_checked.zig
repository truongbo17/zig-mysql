const std = @import("std");

// Dedicated diagnostic, never the default driver allocator. A C allocator
// LD_PRELOAD experiment failed in plaintext too (#111); use Zig's own
// thread-safe checked allocator to distinguish Zig lifetime corruption.
const is_safe_v17 = @hasDecl(std.heap, "SafeAllocator");
const Checked = if (is_safe_v17) std.heap.SafeAllocator else std.heap.DebugAllocator(.{
    .thread_safe = true,
    .safety = true,
});

pub fn main(init: std.process.Init) !void {
    var checked: Checked = if (comptime is_safe_v17)
        .init(std.heap.page_allocator, .{})
    else
        .init;
    defer {
        const result = checked.deinit();
        if (comptime is_safe_v17) {
            if (result != 0) @panic("D3_CHECKED_ALLOCATOR_LEAK");
        } else {
            if (result != .ok) @panic("D3_CHECKED_ALLOCATOR_LEAK");
        }
    }
    // Run the real, fully bounded 1/8/32/64/128-worker pool, including
    // acquireWithTimeout and queryWithTimeout, verified TLS CA and host.
    try @import("high_ccu.zig").run(checked.allocator(), init.io, true);
    std.debug.print("D3_CHECKED_ALLOCATOR_COMPLETE\n", .{});
}
