const std = @import("std");
const client = @import("client.zig");

pub const PoolConfig = struct {
    connection: client.Config,
    /// Maximum number of connections (idle + checked out + connecting).
    max_open: usize = 10,
    /// Maximum number of connections retained for reuse.
    max_idle: usize = 10,
    /// Test idle connections with COM_PING before handing them to borrowers.
    /// Adds one network round trip to each idle reuse. Disable only if your
    /// caller is prepared to retry operations when an idle socket has died.
    validate_on_acquire: bool = true,
    /// Optional bound for idle PINGs. Requires plain TCP/Unix transport;
    /// blocking OpenSSL I/O cannot be cancelled by std.Io.Select.
    health_check_timeout: ?std.Io.Duration = null,
};

pub const Stats = struct {
    open: usize,
    idle: usize,
    /// Includes connections being established, reset or closed during release.
    in_use: usize,
    health_check_failures: usize,
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
    health_check_failures: usize = 0,

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !Pool {
        if (config.max_open == 0 or config.max_idle > config.max_open)
            return error.InvalidPoolConfig;
        if (config.validate_on_acquire and config.health_check_timeout != null and config.connection.tls != null)
            return error.TimedTlsUnsupported;
        return .{ .allocator = allocator, .config = config };
    }

    /// Acquires an exclusive connection, waiting if max_open is reached.
    /// May return error.Canceled if waiting is canceled by the Io runtime.
    pub fn acquire(self: *Pool, io: std.Io) !*client.Client {
        return self.take(io, true);
    }

    /// Bounds the entire acquisition (waiting, stale idle PING and connect)
    /// by a monotonic duration. Expiration returns error.PoolAcquireTimeout.
    /// Uses cancelable std.Io tasks; timed TLS acquisition is unsupported
    /// because the current OpenSSL backend uses blocking I/O.
    ///
    /// If a connection becomes available exactly when the timer expires,
    /// the losing acquire is joined and its connection safely returned to
    /// the pool; no slot or socket is leaked.
    pub fn acquireWithTimeout(self: *Pool, io: std.Io, timeout: std.Io.Duration) !*client.Client {
        if (self.config.connection.tls != null) return error.TimedTlsUnsupported;
        const Outcome = union(enum) {
            acquired: anyerror!*client.Client,
            timer: anyerror!void,
        };
        var slots: [2]Outcome = undefined;
        var select: std.Io.Select(Outcome) = .init(io, &slots);
        defer {
            while (select.cancel()) |remaining| switch (remaining) {
                .acquired => |response| {
                    if (response) |connection| {
                        self.release(io, connection);
                    } else |_| {}
                },
                .timer => {},
            };
        }
        try select.concurrent(.acquired, Pool.acquire, .{ self, io });
        try select.concurrent(.timer, std.Io.sleep, .{ io, timeout, .awake });
        switch (try select.await()) {
            .acquired => |response| return try response,
            .timer => |elapsed| {
                try elapsed;
                return error.PoolAcquireTimeout;
            },
        }
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
                if (self.config.validate_on_acquire) {
                    const checked = if (self.config.health_check_timeout) |duration|
                        connection.pingWithTimeout(io, duration)
                    else
                        connection.ping(io);
                    checked catch {
                        // Never hand out a socket that might have timed out or
                        // been closed while sitting idle. Make room for retry.
                        connection.deinit(io);
                        self.allocator.destroy(connection);
                        self.mutex.lockUncancelable(io);
                        self.health_check_failures += 1;
                        self.open -= 1;
                        self.available.signal(io);
                        // Lock stays held to retry or create a replacement.
                        continue;
                    };
                }
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
        if (retained) {
            self.available.signal(io);
            self.mutex.unlock(io);
            return;
        }
        self.mutex.unlock(io);

        // Keep the slot reserved until the transport really closes. If we
        // decremented open before closing, a concurrent borrower could
        // establish a replacement while the old socket was still alive,
        // briefly exceeding max_open at the MySQL server.
        connection.deinit(io);
        self.allocator.destroy(connection);
        self.releaseSlot(io);
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
            .health_check_failures = self.health_check_failures,
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
    try std.testing.expectError(error.TimedTlsUnsupported, Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = connection.address,
            .username = "test",
            .password = "test",
            .tls = .{ .host = "db.test" },
        },
        .health_check_timeout = .fromSeconds(1),
    }));
}
