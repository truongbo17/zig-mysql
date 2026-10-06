pub const protocol = @import("protocol.zig");
pub const auth = @import("auth.zig");
pub const wire = @import("wire.zig");
pub const Client = @import("client.zig").Client;
pub const Config = @import("client.zig").Config;
pub const Address = @import("client.zig").Address;
pub const TlsConfig = @import("client.zig").TlsConfig;
pub const Result = @import("client.zig").Result;
pub const Param = @import("client.zig").Param;
pub const Statement = @import("client.zig").Statement;

test {
    _ = protocol;
    _ = auth;
    _ = wire;
    _ = @import("client.zig");
}
