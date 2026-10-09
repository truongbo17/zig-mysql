const std = @import("std");
const client = @import("client.zig");

pub const PoolConfig = struct {
    connection: client.Config,
    /// Maximum number of connections (idle + checked out + connecting).
    max_open: usize = 10,
    /// Maximum number of connections retained for reuse.
    max_idle: usize = 10,
};

pub const Stats = struct {
    open: usize,
    idle: usize,
    /// Includes connections still being established or reset on release.
    in_use: usize,
};

/// A bounded, concurrency-safe pool. Every acquired Client must be released
/// exactly once before deinit. Do not use a Client or RowStream after release.
///
/// Config string slices must remain valid until the pool is deinitialized.
/// In particular, this includes credentials, database and TLS configuration.
/// A thread-safe allocator is required when using the pool concurrently.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,
    mutex: std.Io.Mutex = .init,
    available: std.Io.Condition = .init,
    idle: std.ArrayList(*client.Client) = .empty,
    open: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !Pool {
        if (config.max_open == 0 or config.max_idle > config.max_open)
            return error.InvalidPoolConfig;
        return .{ .allocator = allocator, .config = config };
    }

    /// Acquires an exclusive connection, waiting if max_open is reached.
    /// May return error.Canceled if waiting is canceled by the Io runtime.
    pub fn acquire(self: *Pool, io: std.Io) !*client.Client {
        return self.take(io, true);
    }

    /// Returns error.PoolExhausted instead of waiting for a free slot.
    pub fn tryAcquire(self: *Pool, io: std.Io) !*client.Client {
        return self.take(io, false);
    }

    fn take(self: *Pool, io: std.Io, wait: bool) !*client.Client {
        self.mutex.lockUncancelable(io);
        while (true) {
            if (self.idle.items.len > 0) {
                const last = self.idle.items.len - 1;
                const connection = self.idle.items[last];
                self.idle.items.len = last;
                self.mutex.unlock(io);
                return connection;
            }
            if (self.open < self.config.max_open) {
                // Reserve before connecting; otherwise concurrent callers
                // can race past the configured maximum.
                self.open += 1;
                self.mutex.unlock(io);

                const connection = self.allocator.create(client.Client) catch |err| {
                    self.releaseSlot(io);
                    return err;
                };
                errdefer self.allocator.destroy(connection);
                connection.* = client.Client.connect(self.allocator, io, self.config.connection) catch |err| {
                    self.releaseSlot(io);
                    return err;
                };
                return connection;
            }
            if (!wait) {
                self.mutex.unlock(io);
                return error.PoolExhausted;
            }
            self.available.wait(io, &self.mutex) catch |err| {
                self.mutex.unlock(io);
                return err;
            };
        }
    }

    /// Returns an exclusive connection to the pool. The MySQL session is
    /// reset before reuse so transactions, user variables, temporary tables
    /// and prepared statements cannot leak between borrowers.
    /// Broken connections and connections with unread RowStreams are closed.
    /// This operation may perform network I/O.
    pub fn release(self: *Pool, io: std.Io, connection: *client.Client) void {
        var reusable = !connection.broken and !connection.active_stream;
        if (reusable and self.config.max_idle > 0) {
            connection.resetConnection(io) catch {
                reusable = false;
            };
            // A COM_RESET_CONNECTION does not replace an explicit schema
            // selection for callers that expect the initial default schema.
            if (reusable and self.config.connection.database.len > 0) {
                connection.selectDatabase(io, self.config.connection.database) catch {
                    reusable = false;
                };
            }
        } else {
            reusable = false;
        }

        self.mutex.lockUncancelable(io);
        var retained = false;
        if (reusable and self.idle.items.len < self.config.max_idle) {
            retained = blk: {
                self.idle.append(self.allocator, connection) catch break :blk false;
                break :blk true;
            };
        }
        if (!retained) {
            std.debug.assert(self.open > 0);
            self.open -= 1;
        }
        self.available.signal(io);
        self.mutex.unlock(io);

        if (!retained) {
            connection.deinit(io);
            self.allocator.destroy(connection);
        }
    }

    fn releaseSlot(self: *Pool, io: std.Io) void {
        self.mutex.lockUncancelable(io);
        std.debug.assert(self.open > 0);
        self.open -= 1;
        self.available.signal(io);
        self.mutex.unlock(io);
    }

    pub fn stats(self: *Pool, io: std.Io) Stats {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return .{
            .open = self.open,
            .idle = self.idle.items.len,
            .in_use = self.open - self.idle.items.len,
        };
    }

    /// All borrowed connections and in-progress operations must have finished
    /// before deinit. This is not safe to race against acquire or release.
    pub fn deinit(self: *Pool, io: std.Io) void {
        std.debug.assert(self.open == self.idle.items.len);
        for (self.idle.items) |connection| {
            connection.deinit(io);
            self.allocator.destroy(connection);
        }
        self.idle.deinit(self.allocator);
        self.open = 0;
    }
};

test "pool capacity is validated before connecting" {
    const connection = client.Config{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:3306") },
        .username = "test",
        .password = "test",
    };
    try std.testing.expectError(error.InvalidPoolConfig, Pool.init(std.testing.allocator, .{
        .connection = connection,
        .max_open = 0,
    }));
    try std.testing.expectError(error.InvalidPoolConfig, Pool.init(std.testing.allocator, .{
        .connection = connection,
        .max_open = 1,
        .max_idle = 2,
    }));
}
