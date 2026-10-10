pub const protocol = @import("protocol.zig");
pub const auth = @import("auth.zig");
pub const wire = @import("wire.zig");
pub const Client = @import("client.zig").Client;
pub const Config = @import("client.zig").Config;
pub const Address = @import("client.zig").Address;
pub const TlsConfig = @import("client.zig").TlsConfig;
pub const Result = @import("client.zig").Result;
pub const Param = @import("client.zig").Param;
pub const Decimal = @import("decimal.zig").Decimal;
pub const TextRow = @import("text_scan.zig").TextRow;
pub const Temporal = @import("temporal.zig");
pub const Statement = @import("client.zig").Statement;
pub const RowStream = @import("client.zig").RowStream;
pub const Pool = @import("pool.zig").Pool;
pub const PoolConfig = @import("pool.zig").PoolConfig;
pub const PoolStats = @import("pool.zig").Stats;

test {
    _ = protocol;
    _ = auth;
    _ = wire;
    _ = @import("client.zig");
    _ = @import("decimal.zig");
    _ = @import("text_scan.zig");
    _ = @import("temporal.zig");
    _ = @import("pool.zig");
}
