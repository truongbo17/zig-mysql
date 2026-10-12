const std = @import("std");
pub fn main(init: std.process.Init) !void {
    try @import("high_ccu.zig").runWithoutQueryDeadline(std.heap.page_allocator, init.io, true);
}
