const std = @import("std");
pub fn main(init: std.process.Init) !void {
    // Controlled diagnostic for #65: isolate std.process.Init.io lifetime,
    // allocator, worker shutdown and global process teardown from native TLS.
    // The entire verified-TLS pool benchmark uses ONE explicitly owned Io
    // runtime backed by a thread-safe allocator, not the process Io runtime.
    _ = init;
    var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    try @import("high_ccu.zig").run(std.heap.page_allocator, threaded.io(), true);
}
