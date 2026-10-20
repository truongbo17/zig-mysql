const std = @import("std");
pub fn main(init: std.process.Init) !void {
    // Same allocator, Group, Pool and timeout instrumentation as TLS,
    // but plaintext MySQL. Reject TLS attribution if this also fails.
    try @import("high_ccu_tls_checked.zig").runChecked(init, false);
}
