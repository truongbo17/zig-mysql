const std = @import("std");
const protocol = @import("protocol.zig");
const auth = @import("auth.zig");
const temporal = @import("temporal.zig");
const Wire = @import("wire.zig").Wire;
const metrics = @import("command_metrics.zig");

fn classifyMetricError(err: anyerror) metrics.Outcome {
    return switch (err) {
        error.ServerError => .server_error,
        error.QueryTimeout, error.PoolAcquireTimeout => .timeout,
        error.Canceled => .canceled,
        error.TransactionOutcomeUnknown => .ambiguous,
        error.ConnectionBroken, error.ConnectionResetByPeer, error.BrokenPipe, error.EndOfStream => .transport_error,
        else => .client_error,
    };
}

const client_protocol_41: u32 = 1 << 9;
const client_connect_with_db: u32 = 1 << 3;
const client_transactions: u32 = 1 << 13;
const client_secure_connection: u32 = 1 << 15;
const client_plugin_auth: u32 = 1 << 19;
const client_ssl: u32 = 1 << 11;
const client_multi_results: u32 = 1 << 17;
const client_ps_multi_results: u32 = 1 << 18;
const server_more_results_exists: u16 = 0x0008;

pub const Address = union(enum) {
    ip: std.Io.net.IpAddress,
    unix: std.Io.net.UnixAddress,
};

pub const Config = struct {
    address: Address,
    username: []const u8,
    password: []const u8,
    database: []const u8 = "",
    max_message_size: usize = 64 * 1024 * 1024,
    /// Maximum cached server-side prepares on this one connection.
    /// Disabled by default; pooled sessions reset on release, so entries
    /// never cross borrower boundaries.
    statement_cache_capacity: usize = 0,
    connect_timeout: std.Io.Timeout = .none,
    tls: ?TlsConfig = null,
};

pub const TlsConfig = struct {
    /// Expected name in the server certificate, independent of the dialed IP.
    host: []const u8,
    /// Absolute PEM CA path. Null uses OpenSSL's configured default CA paths.
    ca_file: ?[]const u8 = null,
};

pub const ServerError = struct {
    code: u16,
    sql_state: [5]u8,
    message: []const u8,
};

pub const Ok = struct {
    affected_rows: u64,
    last_insert_id: u64,
    status: u16,
    warnings: u16,
};

pub const Column = struct {
    name: []const u8,
    type_code: u8,
    flags: u16,
};

pub const Row = struct {
    values: []const ?[]const u8,
};

pub const Rows = struct {
    columns: []const Column,
    items: []const Row,
};

pub const Param = union(enum) {
    null,
    int: i64,
    uint: u64,
    float: f64,
    text: []const u8,
    /// Exact DECIMAL ASCII, validated prior to writing any packet.
    /// MySQL accepts this as VAR_STRING and casts according to SQL context.
    decimal: []const u8,
    /// MySQL native binary DATE / DATETIME / TIME / TIMESTAMP binds.
    date: temporal.Date,
    datetime: temporal.DateTime,
    time: temporal.Time,
    /// MySQL converts TIMESTAMP according to session time_zone.
    timestamp: temporal.DateTime,
    bytes: []const u8,
    boolean: bool,
};

pub const StatementCacheStats = struct {
    entries: usize,
    hits: u64,
    misses: u64,
    evictions: u64,
};

const CachedStatement = struct {
    sql: []u8,
    statement: Statement,
    last_used: u64,
};

pub const Statement = struct {
    id: u32,
    parameter_count: u16,
    column_count: u16,
    closed: bool = false,
};

/// The returned result owns all text and row memory. Call deinit after use.
pub const Result = struct {
    arena: std.heap.ArenaAllocator,
    value: union(enum) { ok: Ok, rows: Rows },

    pub fn deinit(self: *Result) void {
        self.arena.deinit();
    }
};

/// Buffered response containing every result part of a CALL (rows and OKs).
/// Each item owns its arena independently; always call deinit.
pub const MultiResult = struct {
    allocator: std.mem.Allocator,
    items: []Result,

    pub fn deinit(self: *MultiResult) void {
        for (self.items) |*item| item.deinit();
        self.allocator.free(self.items);
    }
};

/// Iterates CALL result parts without accumulating all resultsets. Each
/// returned Result owns its arena and must be deinitialized by the caller.
/// Deinitializing early drains unread parts; abandoning poisons the socket.
/// Do not reuse a pooled connection until done or deinit has completed.
pub const ProcedureResults = struct {
    client: *Client,
    done: bool = false,
    parts: usize = 0,
    final_ok: ?Ok = null,

    pub fn next(self: *ProcedureResults, io: std.Io) !?Result {
        if (self.client.broken) return error.ConnectionBroken;
        if (self.done) return null;
        if (self.parts >= 256) {
            self.client.broken = true;
            return error.TooManyResults;
        }
        // A server error in a later part is not evidence that all procedure
        // packets have been consumed. Fail closed rather than desynchronize.
        const part = self.client.readResultPart(io, false) catch |err| {
            self.client.broken = true;
            return err;
        };
        self.parts += 1;
        if (!part.more) {
            self.done = true;
            self.client.active_stream = false;
            if (part.result.value == .ok) self.final_ok = part.result.value.ok;
        }
        return part.result;
    }

    /// A separate deadline for fetching one buffered result part, not a
    /// whole CALL deadline. On timeout do not re-use the socket or replay SQL.
    pub fn nextWithTimeout(self: *ProcedureResults, io: std.Io, timeout: std.Io.Duration) !?Result {
        if (self.client.broken) return error.ConnectionBroken;
        if (self.done) return null;
        const Outcome = union(enum) {
            part: anyerror!?Result,
            timer: anyerror!void,
        };
        var slots: [2]Outcome = undefined;
        var select: std.Io.Select(Outcome) = .init(io, &slots);
        defer {
            while (select.cancel()) |remaining| switch (remaining) {
                .part => |response| {
                    if (response) |value| {
                        if (value) |owned| {
                            var result = owned;
                            result.deinit();
                        }
                    } else |_| {}
                },
                .timer => {},
            };
        }
        select.concurrent(.part, ProcedureResults.next, .{ self, io }) catch |err| {
            self.client.broken = true;
            return err;
        };
        select.concurrent(.timer, std.Io.sleep, .{ io, timeout, .awake }) catch |err| {
            self.client.broken = true;
            return err;
        };
        switch (select.await() catch |err| {
            self.client.broken = true;
            return err;
        }) {
            .part => |response| return response catch |err| {
                if (err == error.Canceled) self.client.broken = true;
                return err;
            },
            .timer => |elapsed| {
                self.client.broken = true;
                try elapsed;
                return error.QueryTimeout;
            },
        }
    }

    pub fn abandon(self: *ProcedureResults) void {
        if (!self.done) self.client.broken = true;
        self.done = true;
        self.client.active_stream = false;
    }

    pub fn deinit(self: *ProcedureResults, io: std.Io) void {
        if (!self.done and !self.client.broken) {
            // Drain only the unconsumed part(s), without buffering rows.
            self.client.drainRemaining(io, false) catch {
                self.client.broken = true;
            };
        }
        self.done = true;
        self.client.active_stream = false;
    }
};

const ResultPart = struct {
    result: Result,
    more: bool,
};

/// Text rows arrive one packet at a time. A row's values remain valid until
/// the next call to `next` or `deinit`. Always call `deinit` to drain leftovers.
pub const RowStream = struct {
    client: *Client,
    columns: []const Column,
    metadata_arena: std.heap.ArenaAllocator,
    row_arena: std.heap.ArenaAllocator,
    /// True for prepared binary rows, false for text query rows.
    binary: bool = false,
    done: bool = false,

    pub fn next(self: *RowStream, io: std.Io) !?Row {
        if (self.client.broken) return error.ConnectionBroken;
        if (self.done) return null;
        self.row_arena.deinit();
        self.row_arena = std.heap.ArenaAllocator.init(self.client.allocator);
        const packet = self.client.wire.read(io) catch |err| {
            self.client.broken = true;
            return err;
        };
        defer self.client.allocator.free(packet);
        if (packet.len > 0 and packet[0] == 0xff) {
            // A later streaming SQL error may leave unread result parts.
            self.client.broken = true;
            self.done = true;
            self.client.active_stream = false;
            return self.client.serverFailure(packet);
        }
        if (isEof(packet)) {
            const status = eofStatus(packet) catch |err| {
                self.client.broken = true;
                return err;
            };
            self.done = true;
            self.client.active_stream = false;
            // The old streaming API represents exactly one resultset. Drain
            // additional parts before reporting them, never leave unread data
            // queued for the next pooled borrower.
            if (status & server_more_results_exists != 0) {
                try self.client.drainRemaining(io, self.binary);
                return error.MultipleResults;
            }
            return null;
        }
        errdefer self.client.broken = true;
        var c = protocol.Cursor{ .bytes = packet };
        const a = self.row_arena.allocator();
        const values = try a.alloc(?[]const u8, self.columns.len);
        if (self.binary) {
            if (try c.byte() != 0) return error.Malformed;
            const bitmap = try c.take((self.columns.len + 9) / 8);
            for (values, 0..) |*value, i| {
                const bit = i + 2;
                value.* = if (bitmap[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0)
                    null
                else
                    try parseBinaryValue(a, &c, self.columns[i]);
            }
        } else {
            for (values) |*value| {
                const bytes = try c.lenString();
                value.* = if (bytes) |b| try a.dupe(u8, b) else null;
            }
        }
        if (c.pos != packet.len) return error.Malformed;
        return .{ .values = values };
    }

    /// Applies a timeout to one row fetch. The timeout resets for each call,
    /// not for the whole result set. Nonblocking TLS is also supported.
    /// On timeout the connection is poisoned: caller must deinit the stream
    /// (which skips draining) then discard the connection.
    pub fn nextWithTimeout(self: *RowStream, io: std.Io, timeout: std.Io.Duration) !?Row {
        if (self.client.broken) return error.ConnectionBroken;
        if (self.done) return null;
        const Outcome = union(enum) {
            row: anyerror!?Row,
            timer: anyerror!void,
        };
        var slots: [2]Outcome = undefined;
        var select: std.Io.Select(Outcome) = .init(io, &slots);
        defer {
            // Do not free row_arena until after the losing read is joined.
            while (select.cancel()) |_| {}
        }
        select.concurrent(.row, RowStream.next, .{ self, io }) catch |err| {
            self.client.broken = true;
            return err;
        };
        select.concurrent(.timer, std.Io.sleep, .{ io, timeout, .awake }) catch |err| {
            self.client.broken = true;
            return err;
        };
        switch (select.await() catch |err| {
            self.client.broken = true;
            return err;
        }) {
            .row => |response| return response catch |err| {
                if (err == error.Canceled) self.client.broken = true;
                return err;
            },
            .timer => |elapsed| {
                self.client.broken = true;
                try elapsed;
                return error.QueryTimeout;
            },
        }
    }

    /// Immediately discard row arenas and forbid reuse of the socket.
    /// Unlike deinit this never reads from the network.
    pub fn abandon(self: *RowStream) void {
        self.client.broken = true;
        self.client.active_stream = false;
        self.done = true;
        self.row_arena.deinit();
        self.metadata_arena.deinit();
    }

    pub fn deinit(self: *RowStream, io: std.Io) void {
        // A timeout/cancellation leaves protocol framing unknown. Never
        // attempt to drain from an already broken connection.
        while (!self.done and !self.client.broken) {
            _ = self.next(io) catch {
                self.client.broken = true;
                break;
            };
        }
        self.client.active_stream = false;
        self.row_arena.deinit();
        self.metadata_arena.deinit();
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    wire: Wire,
    last_server_error: ?ServerError = null,
    active_stream: bool = false,
    broken: bool = false,
    /// Last COMMIT/ROLLBACK may have succeeded without acknowledgement.
    transaction_outcome_unknown: bool = false,
    cached_statements: std.ArrayList(CachedStatement) = .empty,
    statement_cache_capacity: usize = 0,
    cache_clock: u64 = 0,
    cache_hits: u64 = 0,
    cache_misses: u64 = 0,
    cache_evictions: u64 = 0,
    /// Optional telemetry, disabled by default; one client has one borrower.
    command_metrics: ?*metrics.Recorder = null,
    metrics_suppressed: bool = false,
    metrics_command_override: ?metrics.Command = null,
    // Populated by Pool only. Standalone clients do not track pool lifecycle.
    pool_created_at: ?@TypeOf(std.Io.Clock.awake.now(@as(std.Io, undefined))) = null,
    pool_released_at: ?@TypeOf(std.Io.Clock.awake.now(@as(std.Io, undefined))) = null,

    /// Bounds TCP connect, MySQL greeting, nonblocking TLS handshake, and
    /// authentication as one cancelable operation. The loser is joined and
    /// any late successful socket is closed instead of leaking its fd.
    pub fn connectWithTimeout(allocator: std.mem.Allocator, io: std.Io, config: Config, timeout: std.Io.Duration) !Client {
        const Outcome = union(enum) {
            connected: anyerror!Client,
            timer: anyerror!void,
        };
        var slots: [2]Outcome = undefined;
        var select: std.Io.Select(Outcome) = .init(io, &slots);
        defer {
            while (select.cancel()) |remaining| switch (remaining) {
                .connected => |response| {
                    if (response) |value| {
                        var stale = value;
                        stale.deinit(io);
                    } else |_| {}
                },
                .timer => {},
            };
        }
        try select.concurrent(.connected, Client.connect, .{ allocator, io, config });
        try select.concurrent(.timer, std.Io.sleep, .{ io, timeout, .awake });
        switch (try select.await()) {
            .connected => |response| return try response,
            .timer => |elapsed| {
                try elapsed;
                return error.ConnectTimeout;
            },
        }
    }

    /// Opens a classic-protocol TCP connection and authenticates.
    /// This first transport supports native auth and cached SHA2 fast auth.
    /// Full SHA2 auth over unencrypted TCP is rejected.
    pub fn connect(allocator: std.mem.Allocator, io: std.Io, config: Config) !Client {
        const stream = switch (config.address) {
            .ip => |address| try address.connect(io, .{ .mode = .stream, .timeout = config.connect_timeout }),
            .unix => |address| try address.connect(io),
        };
        var self = Client{ .allocator = allocator, .wire = .{
            .allocator = allocator,
            .stream = stream,
            .max_message_size = config.max_message_size,
        }, .statement_cache_capacity = config.statement_cache_capacity };
        errdefer self.deinit(io);

        const greeting = try self.wire.read(io);
        defer allocator.free(greeting);
        if (greeting.len > 0 and greeting[0] == 0xff) return self.serverFailure(greeting);
        const hello = try protocol.Handshake.parse(greeting);
        const required = client_protocol_41 | client_secure_connection | client_plugin_auth;
        if (hello.capabilities & required != required) return error.UnsupportedServer;

        const flags = (required | client_transactions |
            client_multi_results | client_ps_multi_results |
            (if (config.tls != null) client_ssl else @as(u32, 0)) |
            (if (config.database.len > 0) client_connect_with_db else @as(u32, 0))) & hello.capabilities;
        if (config.tls != null and flags & client_ssl == 0) return error.TlsUnsupported;
        var response: std.ArrayList(u8) = .empty;
        defer response.deinit(allocator);
        try appendInt(&response, allocator, flags, 4);
        try appendInt(&response, allocator, @min(config.max_message_size, std.math.maxInt(u32)), 4);
        try response.append(allocator, 45); // utf8mb4_general_ci
        try response.appendNTimes(allocator, 0, 23);
        if (config.tls) |tls_config| {
            try self.wire.write(io, response.items); // SSLRequest, sequence 1
            try self.wire.startTls(io, tls_config.host, tls_config.ca_file);
        }
        try appendNul(&response, allocator, config.username);
        try appendAuth(&response, allocator, hello.plugin, config.password, &hello.seed);
        if (config.database.len > 0) try appendNul(&response, allocator, config.database);
        try appendNul(&response, allocator, hello.plugin);
        try self.wire.write(io, response.items);
        try self.finishAuthentication(io, config.password, hello.plugin, &hello.seed, config.address == .unix or config.tls != null);
        return self;
    }

    pub fn deinit(self: *Client, io: std.Io) void {
        self.clearCachedStatements();
        self.cached_statements.deinit(self.allocator);
        if (self.last_server_error) |e| self.allocator.free(e.message);
        self.wire.close(io);
    }

    /// Attaches an externally owned recorder for the duration of one borrower.
    /// Detach before freeing it or handing the client to another thread.
    pub fn setCommandMetrics(self: *Client, recorder: ?*metrics.Recorder) void {
        self.command_metrics = recorder;
    }

    fn observeCommand(self: *Client, io: std.Io, started: ?@TypeOf(std.Io.Clock.awake.now(@as(std.Io, undefined))), category: metrics.Command, outcome: metrics.Outcome) void {
        if (self.metrics_suppressed) return;
        if (self.command_metrics) |recorder| {
            const ns = started.?.untilNow(io, .awake).toNanoseconds();
            const elapsed_us: u64 = @intCast(@max(0, ns) / 1000);
            recorder.record(category, outcome, elapsed_us);
        }
    }

    pub fn ping(self: *Client, io: std.Io) !void {
        const started = if (self.command_metrics != null) std.Io.Clock.awake.now(io) else null;
        var outcome: metrics.Outcome = .success;
        defer self.observeCommand(io, started, .ping, outcome);
        self.command(io, 0x0e, "") catch |err| { outcome = classifyMetricError(err); return err; };
        self.readCommandOk(io) catch |err| { outcome = classifyMetricError(err); return err; };
    }

    /// Changes the default schema for subsequent statements (COM_INIT_DB).
    pub fn selectDatabase(self: *Client, io: std.Io, database: []const u8) !void {
        const started = if (self.command_metrics != null and !self.metrics_suppressed) std.Io.Clock.awake.now(io) else null;
        var outcome: metrics.Outcome = .success;
        defer self.observeCommand(io, started, .session, outcome);
        // A prepared statement belongs to its original schema. Close all
        // handles BEFORE switching; a failed COM_INIT_DB is not a cache hit.
        self.flushCachedStatements(io) catch |err| { outcome = classifyMetricError(err); return err; };
        self.command(io, 0x02, database) catch |err| { outcome = classifyMetricError(err); return err; };
        self.readCommandOk(io) catch |err| { outcome = classifyMetricError(err); return err; };
    }

    /// Restores a clean MySQL session without opening another TCP connection.
    /// Rolls back open transactions, drops temporary tables and user variables,
    /// and invalidates all server-side prepared statements. Do not reuse a
    /// Statement created before this call. Any active RowStream must be drained
    /// before the reset.
    pub fn resetConnection(self: *Client, io: std.Io) !void {
        const started = if (self.command_metrics != null and !self.metrics_suppressed) std.Io.Clock.awake.now(io) else null;
        var outcome: metrics.Outcome = .success;
        defer self.observeCommand(io, started, .session, outcome);
        self.command(io, 0x1f, "") catch |err| { outcome = classifyMetricError(err); return err; };
        self.readCommandOk(io) catch |err| { outcome = classifyMetricError(err); return err; };
        // COM_RESET_CONNECTION invalidates all MySQL statement handles.
        self.clearCachedStatements();
        if (self.last_server_error) |e| {
            self.allocator.free(e.message);
            self.last_server_error = null;
        }
    }

    /// Protects pool session cleanup from a server that accepts
    /// COM_RESET_CONNECTION but never replies. Timed-out sessions are broken.
    pub fn resetConnectionWithTimeout(self: *Client, io: std.Io, timeout: std.Io.Duration) !void {
        return self.withTimeout(void, io, timeout, .session, Client.resetConnection, .{ self, io });
    }

    /// Bounds restoring the caller's configured database on session reset.
    pub fn selectDatabaseWithTimeout(self: *Client, io: std.Io, database: []const u8, timeout: std.Io.Duration) !void {
        return self.withTimeout(void, io, timeout, .session, Client.selectDatabase, .{ self, io, database });
    }

    /// A deadline for the entire PING exchange, not just one socket read.
    /// Timed commands require cancelable std.Io socket operations; the TLS
    /// backend uses nonblocking OpenSSL sockets and cancellable Io waits.
    pub fn pingWithTimeout(self: *Client, io: std.Io, timeout: std.Io.Duration) !void {
        return self.withTimeout(void, io, timeout, .ping, Client.ping, .{ self, io });
    }

    /// Times the entire buffered COM_QUERY exchange (including result rows).
    /// On expiration the socket becomes unusable and must be discarded.
    /// Streaming queryRows has no deadline; finish or drain it explicitly.
    pub fn queryWithTimeout(self: *Client, io: std.Io, sql: []const u8, timeout: std.Io.Duration) !Result {
        return self.withTimeout(Result, io, timeout, .query, Client.query, .{ self, io, sql });
    }

    /// Times a prepared statement's execution and buffered result read.
    /// Server-side statement handles must not be reused on timeout.
    pub fn executeWithTimeout(self: *Client, io: std.Io, statement: Statement, params: []const Param, timeout: std.Io.Duration) !Result {
        return self.withTimeout(Result, io, timeout, .prepared, Client.execute, .{ self, io, statement, params });
    }

    /// Race a command against an elapsed monotonic duration. Joining the losing
    /// task before returning is essential: otherwise that task could continue
    /// reading from a socket after the pool has handed it to another caller.
    fn withTimeout(self: *Client, comptime T: type, io: std.Io, timeout: std.Io.Duration, category: metrics.Command, comptime work: anytype, args: anytype) !T {
        const started = if (self.command_metrics != null and !self.metrics_suppressed) std.Io.Clock.awake.now(io) else null;
        const was_suppressed = self.metrics_suppressed;
        self.metrics_suppressed = true;
        var outcome: metrics.Outcome = .success;
        defer {
            self.metrics_suppressed = was_suppressed;
            self.observeCommand(io, started, category, outcome);
        }
        if (self.broken) { outcome = .transport_error; return error.ConnectionBroken; }
        const Outcome = union(enum) {
            operation: anyerror!T,
            timer: anyerror!void,
        };
        var slots: [2]Outcome = undefined;
        var select: std.Io.Select(Outcome) = .init(io, &slots);
        defer {
            // The command may finish just as the timer fires. Any result
            // discarded due to the race still owns an arena that must be freed.
            while (select.cancel()) |remaining| switch (remaining) {
                .operation => |response| {
                    if (T == Result) {
                        if (response) |value| {
                            var result = value;
                            result.deinit();
                        } else |_| {}
                    } else if (T == RowStream) {
                        if (response) |value| {
                            var stream = value;
                            stream.abandon();
                        } else |_| {}
                    }
                },
                .timer => {},
            };
        }
        select.concurrent(.operation, work, args) catch |err| {
            self.broken = true;
            outcome = classifyMetricError(err);
            return err;
        };
        select.concurrent(.timer, std.Io.sleep, .{ io, timeout, .awake }) catch |err| {
            self.broken = true;
            outcome = classifyMetricError(err);
            return err;
        };
        switch (select.await() catch |err| {
            self.broken = true;
            outcome = classifyMetricError(err);
            return err;
        }) {
            .operation => |response| return response catch |err| {
                if (err == error.Canceled) self.broken = true;
                outcome = classifyMetricError(err);
                return err;
            },
            .timer => |elapsed| {
                try elapsed;
                // Even if MySQL completed on the server, a response may still
                // be buffered in transit; resetting the packet sequence alone
                // would corrupt the next command.
                self.broken = true;
                outcome = if (category == .transaction) .ambiguous else .timeout;
                return error.QueryTimeout;
            },
        }
    }

    pub fn begin(self: *Client, io: std.Io) !void {
        try self.runControlStatement(io, "START TRANSACTION");
    }

    pub fn commit(self: *Client, io: std.Io) !void {
        try self.runControlStatement(io, "COMMIT");
    }

    pub fn rollback(self: *Client, io: std.Io) !void {
        try self.runControlStatement(io, "ROLLBACK");
    }

    /// Explicit, named SAVEPOINT. Never implicitly BEGIN, COMMIT, or retry.
    /// Valid identifiers contain 1..64 ASCII letters, digits or underscores.
    /// The name is quoted after validation and cannot inject SQL.
    pub fn savepoint(self: *Client, io: std.Io, name: []const u8) !void {
        try self.runSavepointCommand(io, "SAVEPOINT ", name);
    }

    /// Rolls back work after the named savepoint without ending the transaction.
    /// MySQL keeps the named savepoint active; RELEASE it when no longer needed.
    pub fn rollbackToSavepoint(self: *Client, io: std.Io, name: []const u8) !void {
        try self.runSavepointCommand(io, "ROLLBACK TO SAVEPOINT ", name);
    }

    /// Deletes a savepoint. Does not commit any SQL changes.
    /// Bounds the COMPLETE COMMIT exchange. If the client loses its response,
    /// the server may have committed despite an error on this socket.
    /// `TransactionOutcomeUnknown` poisons the connection: do not replay SQL.
    pub fn commitWithTimeout(self: *Client, io: std.Io, timeout: std.Io.Duration) !void {
        try self.finishTransactionWithTimeout(io, timeout, Client.commit);
    }

    /// A ROLLBACK with an unread/missing reply also has an unknown outcome.
    /// Use a NEW session to reconcile state, never silently retry.
    pub fn rollbackWithTimeout(self: *Client, io: std.Io, timeout: std.Io.Duration) !void {
        try self.finishTransactionWithTimeout(io, timeout, Client.rollback);
    }

    fn finishTransactionWithTimeout(self: *Client, io: std.Io, timeout: std.Io.Duration, comptime operation: anytype) !void {
        if (self.broken) return error.ConnectionBroken;
        if (self.active_stream) return error.RowsNotConsumed;
        self.withTimeout(void, io, timeout, .transaction, operation, .{ self, io }) catch |err| {
            // A valid server ERR packet explicitly rejected the operation.
            // A timer/transport failure after sending is ambiguous, even if
            // the server finished and its reply was merely lost.
            if (err == error.QueryTimeout or (self.broken and err != error.ServerError)) {
                self.broken = true;
                self.transaction_outcome_unknown = true;
                return error.TransactionOutcomeUnknown;
            }
            return err;
        };
    }

    pub fn releaseSavepoint(self: *Client, io: std.Io, name: []const u8) !void {
        try self.runSavepointCommand(io, "RELEASE SAVEPOINT ", name);
    }

    fn runSavepointCommand(self: *Client, io: std.Io, prefix: []const u8, name: []const u8) !void {
        try validateSavepointName(name);
        // Upper limit: prefix (22) + 2 backticks + 64 identifier characters.
        var sql: [96]u8 = undefined;
        const text = try std.fmt.bufPrint(&sql, "{s}`{s}`", .{ prefix, name });
        try self.runControlStatement(io, text);
    }

    pub fn query(self: *Client, io: std.Io, sql: []const u8) !Result {
        const started = if (self.command_metrics != null) std.Io.Clock.awake.now(io) else null;
        var outcome: metrics.Outcome = .success;
        defer self.observeCommand(io, started, self.metrics_command_override orelse .query, outcome);
        self.command(io, 0x03, sql) catch |err| { outcome = classifyMetricError(err); return err; };
        return self.readResult(io, false) catch |err| { outcome = classifyMetricError(err); return err; };
    }

    /// Buffer every result part (including terminal OK packets) of a CALL.
    /// Multi-statements remain disabled: this does not authorize SQL strings
    /// containing multiple independent statements.
    pub fn queryAll(self: *Client, io: std.Io, sql: []const u8) !MultiResult {
        try self.command(io, 0x03, sql);
        return self.readAllResults(io, false);
    }

    /// Issue exactly one CALL statement and iterate its response parts.
    /// SQL text is passed unchanged: use fixed trusted SQL, never concatenate
    /// untrusted parameters. OUT/INOUT session variables are visible only
    /// after all result parts are consumed or safely drained.
    pub fn callResults(self: *Client, io: std.Io, sql: []const u8) !ProcedureResults {
        try self.command(io, 0x03, sql);
        self.active_stream = true;
        return .{ .client = self };
    }

    /// Stream a SELECT result without buffering all rows.
    pub fn queryRows(self: *Client, io: std.Io, sql: []const u8) !RowStream {
        try self.command(io, 0x03, sql);
        return self.readRowStream(io, false);
    }

    fn readRowStream(self: *Client, io: std.Io, binary: bool) !RowStream {
        const first = self.wire.read(io) catch |err| {
            self.broken = true;
            return err;
        };
        defer self.allocator.free(first);
        if (first.len == 0) {
            self.broken = true;
            return error.Malformed;
        }
        if (first[0] == 0xff) return self.serverFailure(first);
        if (first[0] == 0x00) {
            self.broken = true;
            return error.UnexpectedResult;
        }
        if (first[0] == 0xfb) {
            self.broken = true;
            return error.LocalInfileDisabled;
        }
        errdefer self.broken = true;
        var c = protocol.Cursor{ .bytes = first };
        const n64 = (try c.lenInt()) orelse return error.Malformed;
        if (n64 == 0 or n64 > 4096) return error.Malformed;
        const n: usize = @intCast(n64);
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        const columns = try arena.allocator().alloc(Column, n);
        for (columns) |*column| {
            const packet = try self.wire.read(io);
            defer self.allocator.free(packet);
            if (packet.len > 0 and packet[0] == 0xff) return self.serverFailure(packet);
            column.* = try parseColumn(arena.allocator(), packet);
        }
        try self.expectEof(io);
        self.active_stream = true;
        return .{
            .client = self,
            .columns = columns,
            .metadata_arena = arena,
            .row_arena = std.heap.ArenaAllocator.init(self.allocator),
            .binary = binary,
        };
    }

    /// Timeout applies to the initial COM_QUERY and column metadata phase;
    /// call RowStream.nextWithTimeout separately to time each row fetch.
    pub fn queryRowsWithTimeout(self: *Client, io: std.Io, sql: []const u8, timeout: std.Io.Duration) !RowStream {
        return self.withTimeout(RowStream, io, timeout, .query, Client.queryRows, .{ self, io, sql });
    }

    /// Prepare a statement on the server. Close it when no longer needed.
    pub fn prepare(self: *Client, io: std.Io, sql: []const u8) !Statement {
        try self.command(io, 0x16, sql);
        const packet = self.wire.read(io) catch |err| {
            self.broken = true;
            return err;
        };
        defer self.allocator.free(packet);
        if (packet.len == 0) {
            self.broken = true;
            return error.Malformed;
        }
        if (packet[0] == 0xff) return self.serverFailure(packet);
        errdefer self.broken = true;
        var c = protocol.Cursor{ .bytes = packet };
        if (try c.byte() != 0) return error.Malformed;
        const statement = Statement{
            .id = @intCast(try c.uint(4)),
            .column_count = @intCast(try c.uint(2)),
            .parameter_count = @intCast(try c.uint(2)),
        };
        for (0..statement.parameter_count) |_| try self.discardPacket(io);
        if (statement.parameter_count > 0) try self.expectEof(io);
        for (0..statement.column_count) |_| try self.discardPacket(io);
        if (statement.column_count > 0) try self.expectEof(io);
        return statement;
    }

    /// Execute one prepared statement using an optional per-connection LRU.
    /// Unlike prepare(), no Statement ownership is exposed. The cache is
    /// not shared between pool borrowers; reset/schema change invalidates it.
    pub fn executeCached(self: *Client, io: std.Io, sql: []const u8, params: []const Param) !Result {
        if (self.broken) return error.ConnectionBroken;
        if (self.active_stream) return error.RowsNotConsumed;
        if (self.statement_cache_capacity == 0) {
            var one = try self.prepare(io, sql);
            defer self.closeStatement(io, &one) catch { self.broken = true; };
            return self.execute(io, one, params);
        }
        const stmt = try self.lookupCachedStatement(io, sql);
        return self.execute(io, stmt, params);
    }

    pub fn statementCacheStats(self: *const Client) StatementCacheStats {
        return .{
            .entries = self.cached_statements.items.len,
            .hits = self.cache_hits,
            .misses = self.cache_misses,
            .evictions = self.cache_evictions,
        };
    }

    fn lookupCachedStatement(self: *Client, io: std.Io, sql: []const u8) !Statement {
        self.cache_clock +%= 1;
        for (self.cached_statements.items) |*entry| {
            if (std.mem.eql(u8, entry.sql, sql)) {
                self.cache_hits += 1;
                entry.last_used = self.cache_clock;
                return entry.statement;
            }
        }
        self.cache_misses += 1;
        if (self.cached_statements.items.len >= self.statement_cache_capacity) {
            var victim_index: usize = 0;
            var oldest = self.cached_statements.items[0].last_used;
            for (self.cached_statements.items, 0..) |entry, index| {
                if (entry.last_used < oldest) {
                    oldest = entry.last_used;
                    victim_index = index;
                }
            }
            const victim = self.cached_statements.orderedRemove(victim_index);
            defer self.allocator.free(victim.sql);
            var statement = victim.statement;
            try self.closeStatement(io, &statement);
            self.cache_evictions += 1;
        }
        var statement = try self.prepare(io, sql);
        errdefer self.closeStatement(io, &statement) catch { self.broken = true; };
        const key = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(key);
        try self.cached_statements.append(self.allocator, .{
            .sql = key, .statement = statement, .last_used = self.cache_clock,
        });
        return statement;
    }

    /// Flush one session's cached handles and free their SQL keys. This does
    /// not touch standalone explicitly prepared Statement handles.
    fn flushCachedStatements(self: *Client, io: std.Io) !void {
        if (self.broken) return error.ConnectionBroken;
        if (self.active_stream) return error.RowsNotConsumed;
        for (self.cached_statements.items) |entry| {
            var statement = entry.statement;
            self.closeStatement(io, &statement) catch |err| {
                self.clearCachedStatements();
                self.broken = true;
                return err;
            };
        }
        self.clearCachedStatements();
    }

    fn clearCachedStatements(self: *Client) void {
        for (self.cached_statements.items) |entry| self.allocator.free(entry.sql);
        self.cached_statements.clearRetainingCapacity();
    }

    /// Execute with positional, typed parameters. Results use the binary row protocol.
    pub fn execute(self: *Client, io: std.Io, statement: Statement, params: []const Param) !Result {
        const started = if (self.command_metrics != null) std.Io.Clock.awake.now(io) else null;
        var outcome: metrics.Outcome = .success;
        defer self.observeCommand(io, started, .prepared, outcome);
        self.sendExecute(io, statement, params) catch |err| { outcome = classifyMetricError(err); return err; };
        return self.readResult(io, true) catch |err| { outcome = classifyMetricError(err); return err; };
    }

    /// Stream prepared binary rows with one-row lifetime and bounded memory.
    /// The SELECT result must be fully read or the stream safely deinitialized.
    pub fn executeRows(self: *Client, io: std.Io, statement: Statement, params: []const Param) !RowStream {
        try self.sendExecute(io, statement, params);
        return self.readRowStream(io, true);
    }

    /// Bounded initial COM_STMT_EXECUTE / column metadata phase. Per-row
    /// deadlines are applied independently with RowStream.nextWithTimeout.
    pub fn executeRowsWithTimeout(self: *Client, io: std.Io, statement: Statement, params: []const Param, timeout: std.Io.Duration) !RowStream {
        return self.withTimeout(RowStream, io, timeout, .prepared, Client.executeRows, .{ self, io, statement, params });
    }

    fn sendExecute(self: *Client, io: std.Io, statement: Statement, params: []const Param) !void {
        if (self.broken) return error.ConnectionBroken;
        if (self.active_stream) return error.RowsNotConsumed;
        if (statement.closed) return error.StatementClosed;
        if (params.len != statement.parameter_count) return error.ParameterCountMismatch;
        // Validate all decimal parameters before sending COM_STMT_EXECUTE;
        // malformed local input cannot desynchronize a healthy connection.
        for (params) |p| switch (p) {
            .decimal => |value| _ = try @import("decimal.zig").Decimal.parse(value),
            .date => |value| try temporal.validateDate(value),
            .datetime, .timestamp => |value| try temporal.validateDateTime(value),
            .time => |value| try temporal.validateTime(value),
            else => {},
        };
        self.wire.reset();
        var payload: std.ArrayList(u8) = .empty;
        defer payload.deinit(self.allocator);
        try payload.append(self.allocator, 0x17);
        try appendInt(&payload, self.allocator, statement.id, 4);
        try payload.append(self.allocator, 0); // no server cursor
        try appendInt(&payload, self.allocator, 1, 4); // iteration count
        if (params.len > 0) {
            const bitmap_start = payload.items.len;
            const bitmap_len = (params.len + 7) / 8;
            try payload.appendNTimes(self.allocator, 0, bitmap_len);
            try payload.append(self.allocator, 1); // new parameter types
            for (params, 0..) |p, i| {
                if (p == .null) payload.items[bitmap_start + i / 8] |= @as(u8, 1) << @intCast(i % 8);
                const typ: u8, const flags: u8 = switch (p) {
                    .null => .{ 6, 0 },
                    .int => .{ 8, 0 },
                    .uint => .{ 8, 0x80 },
                    .float => .{ 5, 0 },
                    .text, .decimal => .{ 253, 0 },
                    .date => .{ 10, 0 },
                    .datetime => .{ 12, 0 },
                    .time => .{ 11, 0 },
                    .timestamp => .{ 7, 0 },
                    .bytes => .{ 252, 0 },
                    .boolean => .{ 1, 0 },
                };
                try payload.append(self.allocator, typ);
                try payload.append(self.allocator, flags);
            }
            for (params) |p| switch (p) {
                .null => {},
                .int => |v| try appendInt(&payload, self.allocator, @bitCast(v), 8),
                .uint => |v| try appendInt(&payload, self.allocator, v, 8),
                .float => |v| try appendInt(&payload, self.allocator, @bitCast(v), 8),
                .text, .decimal, .bytes => |v| try appendLenString(&payload, self.allocator, v),
                .date => |v| {
                    try payload.append(self.allocator, 4);
                    try appendInt(&payload, self.allocator, v.year, 2);
                    try payload.append(self.allocator, v.month);
                    try payload.append(self.allocator, v.day);
                },
                .datetime, .timestamp => |v| {
                    try payload.append(self.allocator, if (v.microsecond == 0) 7 else 11);
                    try appendInt(&payload, self.allocator, v.date.year, 2);
                    try payload.append(self.allocator, v.date.month);
                    try payload.append(self.allocator, v.date.day);
                    try payload.append(self.allocator, v.hour);
                    try payload.append(self.allocator, v.minute);
                    try payload.append(self.allocator, v.second);
                    if (v.microsecond != 0)
                        try appendInt(&payload, self.allocator, v.microsecond, 4);
                },
                .time => |v| {
                    try payload.append(self.allocator, if (v.microsecond == 0) 8 else 12);
                    try payload.append(self.allocator, if (v.negative) 1 else 0);
                    try appendInt(&payload, self.allocator, v.hours / 24, 4);
                    try payload.append(self.allocator, @intCast(v.hours % 24));
                    try payload.append(self.allocator, v.minutes);
                    try payload.append(self.allocator, v.seconds);
                    if (v.microsecond != 0)
                        try appendInt(&payload, self.allocator, v.microsecond, 4);
                },
                .boolean => |v| try payload.append(self.allocator, if (v) 1 else 0),
            };
        }
        self.wire.write(io, payload.items) catch |err| {
            self.broken = true;
            return err;
        };
    }

    /// COM_STMT_CLOSE has no server response.
    pub fn closeStatement(self: *Client, io: std.Io, statement: *Statement) !void {
        if (statement.closed) return;
        if (self.broken) return error.ConnectionBroken;
        if (self.active_stream) return error.RowsNotConsumed;
        self.wire.reset();
        var payload: [5]u8 = .{ 0x19, 0, 0, 0, 0 };
        for (0..4) |i| payload[i + 1] = @truncate(statement.id >> @intCast(i * 8));
        self.wire.write(io, &payload) catch |err| {
            self.broken = true;
            return err;
        };
        statement.closed = true;
    }

    // Legacy APIs return one result. Explicitly discard and report additional
    // parts instead of silently handing a desynchronized socket to the pool.
    fn readResult(self: *Client, io: std.Io, binary: bool) !Result {
        var part = try self.readResultPart(io, binary);
        if (!part.more) return part.result;
        part.result.deinit();
        try self.drainRemaining(io, binary);
        return error.MultipleResults;
    }

    fn readAllResults(self: *Client, io: std.Io, binary: bool) !MultiResult {
        var results: std.ArrayList(Result) = .empty;
        errdefer {
            for (results.items) |*item| item.deinit();
            results.deinit(self.allocator);
        }
        // Bound untrusted result-part counts; buffered SQL rows are still
        // subject to the application query/memory budget as before.
        while (results.items.len < 256) {
            var part = self.readResultPart(io, binary) catch |err| {
                // A later result error may leave server framing ambiguous.
                // Never put this connection back in the pool after such a CALL.
                if (results.items.len > 0) self.broken = true;
                return err;
            };
            results.append(self.allocator, part.result) catch |err| {
                part.result.deinit();
                self.broken = true;
                return err;
            };
            if (!part.more) {
                const owned = results.toOwnedSlice(self.allocator) catch |err| {
                    self.broken = true;
                    return err;
                };
                return .{ .allocator = self.allocator, .items = owned };
            }
        }
        self.broken = true;
        return error.TooManyResults;
    }

    // After the first result was returned by a legacy API, consume any
    // subsequent rows/OKs with O(1) row memory. Do not lose a later SQL
    // error; on ambiguous framing or I/O failure permanently poison the socket.
    fn drainRemaining(self: *Client, io: std.Io, binary: bool) !void {
        errdefer self.broken = true;
        for (0..256) |_| {
            if (!(try self.discardResultPart(io, binary))) return;
        }
        return error.TooManyResults;
    }

    fn discardResultPart(self: *Client, io: std.Io, binary: bool) !bool {
        _ = binary; // EOF is unambiguous for both text and binary row framing.
        const first = try self.wire.read(io);
        defer self.allocator.free(first);
        if (first.len == 0) return error.Malformed;
        if (first[0] == 0xff) return self.serverFailure(first);
        if (first[0] == 0x00) {
            const ok = try parseOk(first);
            return ok.status & server_more_results_exists != 0;
        }
        if (first[0] == 0xfb) return error.LocalInfileDisabled;
        var counter = protocol.Cursor{ .bytes = first };
        const n64 = (try counter.lenInt()) orelse return error.Malformed;
        if (n64 == 0 or n64 > 4096 or counter.pos != first.len) return error.Malformed;
        for (0..@as(usize, @intCast(n64))) |_| try self.discardPacket(io);
        try self.expectEof(io);
        while (true) {
            const packet = try self.wire.read(io);
            defer self.allocator.free(packet);
            if (packet.len == 0) return error.Malformed;
            if (packet[0] == 0xff) return self.serverFailure(packet);
            if (isEof(packet)) return (try eofStatus(packet)) & server_more_results_exists != 0;
        }
    }

    fn readResultPart(self: *Client, io: std.Io, binary: bool) !ResultPart {
        const first = self.wire.read(io) catch |err| {
            self.broken = true;
            return err;
        };
        defer self.allocator.free(first);
        if (first.len == 0) {
            self.broken = true;
            return error.Malformed;
        }
        if (first[0] == 0xff) return self.serverFailure(first);
        errdefer self.broken = true;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        if (first[0] == 0x00) {
            const ok = try parseOk(first);
            return .{
                .result = .{ .arena = arena, .value = .{ .ok = ok } },
                .more = ok.status & server_more_results_exists != 0,
            };
        }
        if (first[0] == 0xfb) return error.LocalInfileDisabled;
        var counter = protocol.Cursor{ .bytes = first };
        const n64 = (try counter.lenInt()) orelse return error.Malformed;
        if (n64 == 0 or n64 > 4096 or counter.pos != first.len) return error.Malformed;
        const n: usize = @intCast(n64);
        const a = arena.allocator();
        const columns = try a.alloc(Column, n);
        for (columns) |*column| {
            const packet = try self.wire.read(io);
            defer self.allocator.free(packet);
            if (packet.len > 0 and packet[0] == 0xff) return self.serverFailure(packet);
            column.* = try parseColumn(a, packet);
        }
        const metadata_end = try self.wire.read(io);
        defer self.allocator.free(metadata_end);
        _ = try eofStatus(metadata_end);
        var rows: std.ArrayList(Row) = .empty;
        while (true) {
            const packet = try self.wire.read(io);
            defer self.allocator.free(packet);
            if (packet.len > 0 and packet[0] == 0xff) return self.serverFailure(packet);
            if (isEof(packet)) {
                const status = try eofStatus(packet);
                return .{
                    .result = .{ .arena = arena, .value = .{ .rows = .{
                        .columns = columns,
                        .items = try rows.toOwnedSlice(a),
                    } } },
                    .more = status & server_more_results_exists != 0,
                };
            }
            var c = protocol.Cursor{ .bytes = packet };
            const values = try a.alloc(?[]const u8, n);
            if (binary) {
                if (try c.byte() != 0) return error.Malformed;
                const bitmap = try c.take((n + 9) / 8);
                for (values, 0..) |*value, i| {
                    const bit = i + 2;
                    value.* = if (bitmap[bit / 8] & (@as(u8, 1) << @intCast(bit % 8)) != 0)
                        null
                    else
                        try parseBinaryValue(a, &c, columns[i]);
                }
            } else {
                for (values) |*value| {
                    const bytes = try c.lenString();
                    value.* = if (bytes) |b| try a.dupe(u8, b) else null;
                }
            }
            if (c.pos != packet.len) return error.Malformed;
            try rows.append(a, .{ .values = values });
        }
    }

    fn discardPacket(self: *Client, io: std.Io) !void {
        const packet = self.wire.read(io) catch |err| {
            self.broken = true;
            return err;
        };
        defer self.allocator.free(packet);
        if (packet.len > 0 and packet[0] == 0xff) return self.serverFailure(packet);
    }

    fn expectEof(self: *Client, io: std.Io) !void {
        const packet = self.wire.read(io) catch |err| {
            self.broken = true;
            return err;
        };
        defer self.allocator.free(packet);
        if (packet.len > 0 and packet[0] == 0xff) return self.serverFailure(packet);
        _ = eofStatus(packet) catch |err| {
            self.broken = true;
            return err;
        };
    }

    fn command(self: *Client, io: std.Io, code: u8, data: []const u8) !void {
        if (self.broken) return error.ConnectionBroken;
        if (self.active_stream) return error.RowsNotConsumed;
        self.wire.reset();
        const payload = try self.allocator.alloc(u8, data.len + 1);
        defer self.allocator.free(payload);
        payload[0] = code;
        @memcpy(payload[1..], data);
        self.wire.write(io, payload) catch |err| {
            self.broken = true;
            return err;
        };
    }

    /// An unexpected or truncated response means the protocol is no longer
    /// synchronized; the connection cannot safely be reused by a pool.
    fn readCommandOk(self: *Client, io: std.Io) !void {
        const packet = self.wire.read(io) catch |err| {
            self.broken = true;
            return err;
        };
        defer self.allocator.free(packet);
        if (packet.len > 0 and packet[0] == 0xff) return self.serverFailure(packet);
        _ = parseOk(packet) catch |err| {
            self.broken = true;
            return err;
        };
    }

    fn runControlStatement(self: *Client, io: std.Io, sql: []const u8) !void {
        const previous = self.metrics_command_override;
        self.metrics_command_override = .transaction;
        defer self.metrics_command_override = previous;
        var result = try self.query(io, sql);
        defer result.deinit();
        if (result.value != .ok) return error.UnexpectedResult;
    }

    fn finishAuthentication(self: *Client, io: std.Io, password: []const u8, initial_plugin: []const u8, initial_seed: []const u8, secure_local: bool) !void {
        var plugin = initial_plugin;
        var seed = initial_seed;
        var plugin_storage: [128]u8 = undefined;
        var seed_storage: [128]u8 = undefined;
        var exchanges: usize = 0;
        while (exchanges < 8) : (exchanges += 1) {
            const packet = try self.wire.read(io);
            defer self.allocator.free(packet);
            if (packet.len == 0) return error.Malformed;
            switch (packet[0]) {
                0x00 => return,
                0xff => return self.serverFailure(packet),
                0xfe => {
                    var c = protocol.Cursor{ .bytes = packet[1..] };
                    const next_plugin = try c.nulString();
                    const next_seed = std.mem.trimEnd(u8, packet[1 + c.pos ..], "\x00");
                    if (next_plugin.len > plugin_storage.len or next_seed.len > seed_storage.len) return error.Malformed;
                    @memcpy(plugin_storage[0..next_plugin.len], next_plugin);
                    @memcpy(seed_storage[0..next_seed.len], next_seed);
                    plugin = plugin_storage[0..next_plugin.len];
                    seed = seed_storage[0..next_seed.len];
                    const reply = try authResponse(self.allocator, plugin, password, seed);
                    defer self.allocator.free(reply);
                    try self.wire.write(io, reply);
                },
                0x01 => {
                    if (!std.mem.eql(u8, plugin, "caching_sha2_password") or packet.len < 2) return error.UnsupportedAuthentication;
                    switch (packet[1]) {
                        0x03 => {}, // fast auth succeeded; final OK follows
                        0x04 => {
                            if (!secure_local) return error.SecureTransportRequired;
                            const clear = try self.allocator.alloc(u8, password.len + 1);
                            defer self.allocator.free(clear);
                            @memcpy(clear[0..password.len], password);
                            clear[password.len] = 0;
                            try self.wire.write(io, clear);
                        },
                        else => return error.UnsupportedAuthentication,
                    }
                },
                else => return error.Malformed,
            }
        }
        return error.TooManyAuthenticationExchanges;
    }

    fn serverFailure(self: *Client, packet: []const u8) anyerror {
        var state: [5]u8 = "HY000".*;
        if (packet.len >= 9 and packet[3] == '#') @memcpy(&state, packet[4..9]);
        const start: usize = if (packet.len >= 9 and packet[3] == '#') 9 else 3;
        const message = self.allocator.dupe(u8, if (packet.len >= start) packet[start..] else "") catch return error.OutOfMemory;
        if (self.last_server_error) |e| self.allocator.free(e.message);
        self.last_server_error = .{
            .code = if (packet.len >= 3) @as(u16, packet[1]) | @as(u16, packet[2]) << 8 else 0,
            .sql_state = state,
            .message = message,
        };
        return error.ServerError;
    }
};

fn authResponse(allocator: std.mem.Allocator, plugin: []const u8, password: []const u8, seed: []const u8) ![]u8 {
    if (password.len == 0) return allocator.alloc(u8, 0);
    if (std.mem.eql(u8, plugin, "mysql_native_password")) {
        return allocator.dupe(u8, &auth.nativePassword(password, seed));
    }
    if (std.mem.eql(u8, plugin, "caching_sha2_password")) {
        return allocator.dupe(u8, &auth.cachingSha2Password(password, seed));
    }
    return error.UnsupportedAuthentication;
}

fn appendAuth(out: *std.ArrayList(u8), allocator: std.mem.Allocator, plugin: []const u8, password: []const u8, seed: []const u8) !void {
    const response = try authResponse(allocator, plugin, password, seed);
    defer allocator.free(response);
    try out.append(allocator, @intCast(response.len));
    try out.appendSlice(allocator, response);
}

fn appendNul(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    if (std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidConfiguration;
    try out.appendSlice(allocator, text);
    try out.append(allocator, 0);
}

fn appendInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, number: u64, count: usize) !void {
    for (0..count) |i| try out.append(allocator, @truncate(number >> @intCast(i * 8)));
}

fn appendLenString(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8) !void {
    const n = text.len;
    if (n < 251) {
        try out.append(allocator, @intCast(n));
    } else if (n <= std.math.maxInt(u16)) {
        try out.append(allocator, 0xfc);
        try appendInt(out, allocator, n, 2);
    } else if (n <= 0xff_ff_ff) {
        try out.append(allocator, 0xfd);
        try appendInt(out, allocator, n, 3);
    } else {
        try out.append(allocator, 0xfe);
        try appendInt(out, allocator, n, 8);
    }
    try out.appendSlice(allocator, text);
}

fn validateSavepointName(name: []const u8) !void {
    if (name.len == 0 or name.len > 64) return error.InvalidSavepointName;
    for (name) |ch| {
        if (!((ch >= 'a' and ch <= 'z') or
            (ch >= 'A' and ch <= 'Z') or
            (ch >= '0' and ch <= '9') or ch == '_'))
            return error.InvalidSavepointName;
    }
}

test "savepoint identifiers reject SQL injection before sending packets" {
    for ([_][]const u8{ "", "foo-bar", "a`b", "a b", "x;DROP TABLE t", "a\\nb", "ä" }) |name|
        try std.testing.expectError(error.InvalidSavepointName, validateSavepointName(name));
    const long: [65]u8 = @splat('x');
    try std.testing.expectError(error.InvalidSavepointName, validateSavepointName(&long));
    for ([_][]const u8{ "s1", "Nested_42", "1", "SELECT" }) |name|
        try validateSavepointName(name);
}

fn isEof(packet: []const u8) bool {
    return packet.len > 0 and packet.len < 9 and packet[0] == 0xfe;
}

fn eofStatus(packet: []const u8) !u16 {
    if (!isEof(packet) or packet.len != 5) return error.Malformed;
    return @as(u16, packet[3]) | (@as(u16, packet[4]) << 8);
}

fn parseOk(packet: []const u8) !Ok {
    var c = protocol.Cursor{ .bytes = packet };
    if (try c.byte() != 0) return error.Malformed;
    const affected = (try c.lenInt()) orelse return error.Malformed;
    const insert_id = (try c.lenInt()) orelse return error.Malformed;
    return .{
        .affected_rows = affected,
        .last_insert_id = insert_id,
        .status = @intCast(try c.uint(2)),
        .warnings = @intCast(try c.uint(2)),
    };
}

fn parseColumn(allocator: std.mem.Allocator, packet: []const u8) !Column {
    var c = protocol.Cursor{ .bytes = packet };
    for (0..4) |_| _ = (try c.lenString()) orelse return error.Malformed;
    const name = (try c.lenString()) orelse return error.Malformed;
    _ = (try c.lenString()) orelse return error.Malformed;
    if (try c.byte() != 0x0c) return error.Malformed;
    _ = try c.uint(2); // charset
    _ = try c.uint(4); // maximum column length
    const type_code = try c.byte();
    const flags: u16 = @intCast(try c.uint(2));
    return .{ .name = try allocator.dupe(u8, name), .type_code = type_code, .flags = flags };
}

fn parseBinaryValue(allocator: std.mem.Allocator, c: *protocol.Cursor, column: Column) ![]const u8 {
    const unsigned = column.flags & 32 != 0;
    const width: u4 = switch (column.type_code) {
        1 => 1, // TINY
        2, 13 => 2, // SHORT, YEAR
        3, 9 => 4, // LONG, INT24
        8 => 8, // LONGLONG
        else => 0,
    };
    if (width != 0) {
        const raw = try c.uint(width);
        if (unsigned) return std.fmt.allocPrint(allocator, "{d}", .{raw});
        const signed: i64 = switch (width) {
            1 => @as(i8, @bitCast(@as(u8, @truncate(raw)))),
            2 => @as(i16, @bitCast(@as(u16, @truncate(raw)))),
            4 => @as(i32, @bitCast(@as(u32, @truncate(raw)))),
            8 => @bitCast(raw),
            else => unreachable,
        };
        return std.fmt.allocPrint(allocator, "{d}", .{signed});
    }
    switch (column.type_code) {
        4 => {
            const raw: u32 = @intCast(try c.uint(4));
            return std.fmt.allocPrint(allocator, "{d}", .{@as(f32, @bitCast(raw))});
        },
        5 => {
            const raw = try c.uint(8);
            return std.fmt.allocPrint(allocator, "{d}", .{@as(f64, @bitCast(raw))});
        },
        7, 10, 12, 14 => {
            const len = try c.byte();
            if (len == 0) return allocator.dupe(u8, "0000-00-00");
            if (len != 4 and len != 7 and len != 11) return error.Malformed;
            const year = try c.uint(2);
            const month = try c.byte();
            const day = try c.byte();
            if (len == 4) return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, month, day });
            const hour = try c.byte();
            const minute = try c.byte();
            const second = try c.byte();
            if (len == 7) return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}", .{ year, month, day, hour, minute, second });
            const micro = try c.uint(4);
            return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2} {d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ year, month, day, hour, minute, second, micro });
        },
        11 => {
            const len = try c.byte();
            if (len == 0) return allocator.dupe(u8, "00:00:00");
            if (len != 8 and len != 12) return error.Malformed;
            const negative = try c.byte() != 0;
            const days = try c.uint(4);
            const hours = try c.byte();
            const minute = try c.byte();
            const second = try c.byte();
            const total_hours = days * 24 + hours;
            const sign: []const u8 = if (negative) "-" else "";
            if (len == 8) return std.fmt.allocPrint(allocator, "{s}{d:0>2}:{d:0>2}:{d:0>2}", .{ sign, total_hours, minute, second });
            const micro = try c.uint(4);
            return std.fmt.allocPrint(allocator, "{s}{d:0>2}:{d:0>2}:{d:0>2}.{d:0>6}", .{ sign, total_hours, minute, second, micro });
        },
        0, 15, 16, 245, 246, 247, 248, 249, 250, 251, 252, 253, 254, 255 => {
            const text = (try c.lenString()) orelse return error.Malformed;
            return allocator.dupe(u8, text);
        },
        else => return error.UnsupportedColumnType,
    }
}

test "parse OK packet and column metadata" {
    const ok = try parseOk(&.{ 0, 2, 7, 2, 0, 0, 0 });
    try std.testing.expectEqual(@as(u64, 2), ok.affected_rows);
    try std.testing.expectEqual(@as(u64, 7), ok.last_insert_id);
    const col = try parseColumn(std.testing.allocator, &.{ 3, 'd', 'e', 'f', 0, 0, 0, 2, 'i', 'd', 2, 'i', 'd', 12, 45, 0, 11, 0, 0, 0, 3, 0, 0, 0, 0 });
    defer std.testing.allocator.free(col.name);
    try std.testing.expectEqualStrings("id", col.name);
}

test "EOF status and more-results flag require valid terminator" {
    try std.testing.expectEqual(@as(u16, 8), try eofStatus(&.{ 0xfe, 0, 0, 8, 0 }));
    try std.testing.expectEqual(@as(u16, 0), try eofStatus(&.{ 0xfe, 0, 0, 0, 0 }));
    try std.testing.expectError(error.Malformed, eofStatus(&.{0xfe}));
    try std.testing.expectError(error.Malformed, eofStatus(&.{ 0xfe, 0, 0, 8, 0, 0 }));
    const ok = try parseOk(&.{ 0, 0, 0, 8, 0, 0, 0 });
    try std.testing.expect(ok.status & server_more_results_exists != 0);
}
