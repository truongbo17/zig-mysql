pub const protocol = @import("protocol.zig");
pub const auth = @import("auth.zig");
pub const wire = @import("wire.zig");
pub const Client = @import("client.zig").Client;
pub const Config = @import("client.zig").Config;
pub const Result = @import("client.zig").Result;

test {
    _ = protocol;
    _ = auth;
    _ = wire;
    _ = @import("client.zig");
}
