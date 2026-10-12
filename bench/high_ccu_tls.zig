const std = @import("std");
pub fn main(init: std.process.Init) !void {
    // Benchmark pool allocation occurs across multiple std.Io workers.
    try @import("high_ccu.zig").run(std.heap.page_allocator, init.io, true);
}
