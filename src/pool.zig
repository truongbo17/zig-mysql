const std = @import("std");
const client = @import("client.zig");

pub const PoolConfig = struct {
    connection: client.Config,
    /// Optional equivalent MySQL endpoints, attempted in order only when
    /// opening a NEW connection fails. No SQL is automatically replayed.
    /// All endpoints must have equivalent roles, schemas and credentials.
    /// Slice lifetime must cover the entire pool lifetime.
    failover_addresses: []const client.Address = &.{},
    /// Total timeout per TCP/TLS connect and authentication attempt.
    /// Applied separately to the primary and each fallback address.
    connect_attempt_timeout: ?std.Io.Duration = .fromSeconds(5),
    /// Maximum number of connections (idle + checked out + connecting).
    max_open: usize = 10,
    /// Maximum number of connections retained for reuse.
    max_idle: usize = 10,
    /// Test idle connections with COM_PING before handing them to borrowers.
    /// Adds one network round trip to each idle reuse. Disable only if your
    /// caller is prepared to retry operations when an idle socket has died.
    validate_on_acquire: bool = true,
    /// Optional bound for idle PINGs; works with nonblocking TLS as well.
    /// Defaults to 5s to avoid indefinitely stalled borrow checks.
    health_check_timeout: ?std.Io.Duration = .fromSeconds(5),
    /// Per-command deadline for resetting a returned session and restoring
    /// its original database. Null disables the bound (not recommended).
    session_reset_timeout: ?std.Io.Duration = .fromSeconds(5),
    /// Close idle sockets older than this monotonic duration on next checkout.
    /// No background scavenger thread is started.
    max_idle_time: ?std.Io.Duration = null,
    /// Recycle connections older than this at release or next checkout.
    /// Active queries are never forcibly interrupted by this setting.
    max_connection_age: ?std.Io.Duration = null,
};

pub const Stats = struct {
    open: usize,
    idle: usize,
    /// Includes connections being established, reset or closed during release.
    in_use: usize,
    health_check_failures: usize,
    expired_connections: usize,
    /// Cumulative connection establishments, including recycled sessions.
    connections_created: usize,
    /// Cumulative successful socket closures (excludes deinit teardown).
    connections_closed: usize,
    /// Times a borrower encountered a fully occupied pool and waited.
    waits: usize,
    /// Acquisition deadlines elapsed.
    acquire_timeouts: usize,
    /// Failed attempts to open/authenticate a new connection.
    connect_failures: usize,
    /// Connections discarded due to failure of session reset/schema restore.
    reset_failures: usize,
    /// Number of attempts to non-primary endpoints.
    failover_attempts: usize,
    /// Number of successful connections to non-primary endpoints.
    failover_successes: usize,

    /// Prometheus text exposition with fixed, label-free metric names.
    /// The returned buffer is owned by the caller. Never include passwords
    /// or untrusted endpoint names in metrics labels.
    pub fn formatPrometheus(self: Stats, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator,
            "# TYPE zig_mysql_pool_open gauge\n" ++
            "zig_mysql_pool_open {d}\n" ++
            "# TYPE zig_mysql_pool_idle gauge\n" ++
            "zig_mysql_pool_idle {d}\n" ++
            "# TYPE zig_mysql_pool_in_use gauge\n" ++
            "zig_mysql_pool_in_use {d}\n" ++
            "# TYPE zig_mysql_pool_connections_created_total counter\n" ++
            "zig_mysql_pool_connections_created_total {d}\n" ++
            "# TYPE zig_mysql_pool_connections_closed_total counter\n" ++
            "zig_mysql_pool_connections_closed_total {d}\n" ++
            "# TYPE zig_mysql_pool_connect_failures_total counter\n" ++
            "zig_mysql_pool_connect_failures_total {d}\n" ++
            "# TYPE zig_mysql_pool_health_check_failures_total counter\n" ++
            "zig_mysql_pool_health_check_failures_total {d}\n" ++
            "# TYPE zig_mysql_pool_reset_failures_total counter\n" ++
            "zig_mysql_pool_reset_failures_total {d}\n" ++
            "# TYPE zig_mysql_pool_expired_connections_total counter\n" ++
            "zig_mysql_pool_expired_connections_total {d}\n" ++
            "# TYPE zig_mysql_pool_waits_total counter\n" ++
            "zig_mysql_pool_waits_total {d}\n" ++
            "# TYPE zig_mysql_pool_acquire_timeouts_total counter\n" ++
            "zig_mysql_pool_acquire_timeouts_total {d}\n" ++
            "# TYPE zig_mysql_pool_failover_attempts_total counter\n" ++
            "zig_mysql_pool_failover_attempts_total {d}\n" ++
            "# TYPE zig_mysql_pool_failover_successes_total counter\n" ++
            "zig_mysql_pool_failover_successes_total {d}\n",
            .{
                self.open, self.idle, self.in_use,
                self.connections_created, self.connections_closed,
                self.connect_failures, self.health_check_failures,
                self.reset_failures, self.expired_connections,
                self.waits, self.acquire_timeouts,
                self.failover_attempts, self.failover_successes,
            });
    }
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
    expired_connections: usize = 0,
    connections_created: usize = 0,
    connections_closed: usize = 0,
    waits: usize = 0,
    acquire_timeouts: usize = 0,
    connect_failures: usize = 0,
    reset_failures: usize = 0,
    failover_attempts: usize = 0,
    failover_successes: usize = 0,

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

    /// Bounds the entire acquisition (waiting, stale idle PING and connect)
    /// by a monotonic duration. Expiration returns error.PoolAcquireTimeout.
    /// Uses cancelable std.Io tasks, including nonblocking OpenSSL TLS.
    ///
    /// If a connection becomes available exactly when the timer expires,
    /// the losing acquire is joined and its connection safely returned to
    /// the pool; no slot or socket is leaked.
    pub fn acquireWithTimeout(self: *Pool, io: std.Io, timeout: std.Io.Duration) !*client.Client {
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
                self.mutex.lockUncancelable(io);
                self.acquire_timeouts += 1;
                self.mutex.unlock(io);
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
                if (self.isExpired(io, connection, true)) {
                    connection.deinit(io);
                    self.allocator.destroy(connection);
                    self.mutex.lockUncancelable(io);
                    self.expired_connections += 1;
                    self.connections_closed += 1;
                    self.open -= 1;
                    self.available.signal(io);
                    continue;
                }
                if (self.config.validate_on_acquire) {
                    const checked = if (self.config.health_check_timeout) |duration|
                        connection.pingWithTimeout(io, duration)
                    else
                        connection.ping(io);
                    checked catch |err| {
                        // Never hand out a socket that might have timed out or
                        // been closed while sitting idle. Make room for retry.
                        connection.deinit(io);
                        self.allocator.destroy(connection);
                        self.mutex.lockUncancelable(io);
                        self.health_check_failures += 1;
                        self.connections_closed += 1;
                        self.open -= 1;
                        self.available.signal(io);
                        // Propagate cancellation instead of attempting another
                        // network connection from a timed-out acquire task.
                        if (err == error.Canceled) {
                            self.mutex.unlock(io);
                            return error.Canceled;
                        }
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
                connection.* = self.connectConfigured(io) catch |err| {
                    self.releaseSlot(io);
                    return err;
                };
                self.mutex.lockUncancelable(io);
                self.connections_created += 1;
                self.mutex.unlock(io);
                connection.pool_created_at = std.Io.Clock.awake.now(io);
                return connection;
            }
            if (!wait) {
                self.mutex.unlock(io);
                return error.PoolExhausted;
            }
            self.waits += 1;
            self.available.wait(io, &self.mutex) catch |err| {
                self.mutex.unlock(io);
                return err;
            };
        }
    }

    /// Fail over only during connection setup. Never replay an in-flight
    /// statement or transaction, whose server-side outcome may be unknown.
    fn connectConfigured(self: *Pool, io: std.Io) !client.Client {
        var index: usize = 0;
        while (index <= self.config.failover_addresses.len) : (index += 1) {
            var cfg = self.config.connection;
            if (index > 0) {
                cfg.address = self.config.failover_addresses[index - 1];
                self.mutex.lockUncancelable(io);
                self.failover_attempts += 1;
                self.mutex.unlock(io);
            }
            const attempt = if (self.config.connect_attempt_timeout) |timeout|
                client.Client.connectWithTimeout(self.allocator, io, cfg, timeout)
            else
                client.Client.connect(self.allocator, io, cfg);
            if (attempt) |connection| {
                if (index > 0) {
                    self.mutex.lockUncancelable(io);
                    self.failover_successes += 1;
                    self.mutex.unlock(io);
                }
                return connection;
            } else |err| {
                self.mutex.lockUncancelable(io);
                self.connect_failures += 1;
                self.mutex.unlock(io);
                // Never mask an authentication, policy, certificate or local
                // configuration failure by silently trying another server.
                // Only connection/transport establishment failures may fall
                // through to a different endpoint.
                if (err == error.Canceled or err == error.OutOfMemory or
                    err == error.ServerError or err == error.InvalidConfiguration or
                    err == error.UnsupportedAuthentication or err == error.SecureTransportRequired or
                    err == error.InvalidTlsHost or err == error.TlsCertificateInvalid or
                    err == error.TlsCertificateMissing or err == error.TlsCaLoadFailed or
                    err == error.TlsHostFailed or err == error.TlsHandshakeFailed or
                    err == error.TlsUnsupported or err == error.UnsupportedTlsPlatform)
                    return err;
                if (index == self.config.failover_addresses.len) return err;
            }
        }
        unreachable;
    }

    /// Returns an exclusive connection to the pool. The MySQL session is
    /// reset before reuse so transactions, user variables, temporary tables
    /// and prepared statements cannot leak between borrowers.
    /// Broken connections and connections with unread RowStreams are closed.
    /// This operation may perform network I/O.
    pub fn release(self: *Pool, io: std.Io, connection: *client.Client) void {
        const expired = self.isExpired(io, connection, false);
        var reusable = !connection.broken and !connection.active_stream and !expired;
        var reset_failed = false;
        if (reusable and self.config.max_idle > 0) {
            const reset = if (self.config.session_reset_timeout) |timeout|
                connection.resetConnectionWithTimeout(io, timeout)
            else
                connection.resetConnection(io);
            reset catch {
                reusable = false;
                reset_failed = true;
            };
            // A COM_RESET_CONNECTION does not replace an explicit schema
            // selection for callers that expect the initial default schema.
            if (reusable and self.config.connection.database.len > 0) {
                const restored = if (self.config.session_reset_timeout) |timeout|
                    connection.selectDatabaseWithTimeout(io, self.config.connection.database, timeout)
                else
                    connection.selectDatabase(io, self.config.connection.database);
                restored catch {
                    reusable = false;
                    reset_failed = true;
                };
            }
        } else {
            reusable = false;
        }

        self.mutex.lockUncancelable(io);
        if (expired) self.expired_connections += 1;
        if (reset_failed) self.reset_failures += 1;
        var retained = false;
        if (reusable and self.idle.items.len < self.config.max_idle) {
            connection.pool_released_at = std.Io.Clock.awake.now(io);
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
        self.mutex.lockUncancelable(io);
        self.connections_closed += 1;
        self.mutex.unlock(io);
        self.releaseSlot(io);
    }

    fn isExpired(self: *Pool, io: std.Io, connection: *client.Client, idle_checkout: bool) bool {
        if (self.config.max_connection_age) |age| {
            if (connection.pool_created_at) |created| {
                if (created.untilNow(io, .awake).toNanoseconds() >= age.toNanoseconds())
                    return true;
            }
        }
        if (idle_checkout) {
            if (self.config.max_idle_time) |duration| {
                if (connection.pool_released_at) |released| {
                    if (released.untilNow(io, .awake).toNanoseconds() >= duration.toNanoseconds())
                        return true;
                }
            }
        }
        return false;
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
            .expired_connections = self.expired_connections,
            .connections_created = self.connections_created,
            .connections_closed = self.connections_closed,
            .waits = self.waits,
            .acquire_timeouts = self.acquire_timeouts,
            .connect_failures = self.connect_failures,
            .reset_failures = self.reset_failures,
            .failover_attempts = self.failover_attempts,
            .failover_successes = self.failover_successes,
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
    _ = try Pool.init(std.testing.allocator, .{
        .connection = .{
            .address = connection.address,
            .username = "test",
            .password = "test",
            .tls = .{ .host = "db.test" },
        },
        .health_check_timeout = .fromSeconds(1),
    });
}

test "Prometheus pool exposition contains expected metrics and no configuration secrets" {
    const stats = Stats{
        .open = 3,
        .idle = 1,
        .in_use = 2,
        .health_check_failures = 4,
        .expired_connections = 5,
        .connections_created = 8,
        .connections_closed = 5,
        .waits = 9,
        .acquire_timeouts = 1,
        .connect_failures = 2,
        .reset_failures = 0,
        .failover_attempts = 3,
        .failover_successes = 1,
    };
    const metrics = try stats.formatPrometheus(std.testing.allocator);
    defer std.testing.allocator.free(metrics);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "zig_mysql_pool_open 3\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "zig_mysql_pool_failover_successes_total 1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, metrics, "# TYPE zig_mysql_pool_acquire_timeouts_total counter\n") != null);
}
