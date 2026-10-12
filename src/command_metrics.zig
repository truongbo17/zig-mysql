const std = @import("std");

/// Low-cardinality command types. SQL text, bound values, server addresses,
/// user names and credentials must never be used as metric labels.
pub const Command = enum {
    query,
    prepared,
    transaction,
    ping,
    session,
};

/// Fixed classification independent of untrusted server messages.
pub const Outcome = enum {
    success,
    server_error,
    timeout,
    canceled,
    transport_error,
    client_error,
    ambiguous,
};

/// Inclusive upper limits in microseconds; the final bucket is +Inf.
pub const latency_buckets_us = [_]u64{
    100, 250, 500, 1_000, 2_500, 5_000, 10_000,
    25_000, 50_000, 100_000, 250_000, 500_000,
    1_000_000, 5_000_000,
};
pub const command_count = @intFromEnum(Command.session) + 1;
pub const outcome_count = @intFromEnum(Outcome.ambiguous) + 1;
pub const bucket_count = latency_buckets_us.len + 1;

/// Per-connection (single-borrower) telemetry accumulator. Not thread-safe:
/// external aggregation must synchronize when publishing across connections.
/// This collector does not retain SQL or parameter bytes.
pub const Recorder = struct {
    counts: [command_count][outcome_count]u64 = std.mem.zeroes([command_count][outcome_count]u64),
    buckets: [command_count][bucket_count]u64 = std.mem.zeroes([command_count][bucket_count]u64),
    total_duration_us: [command_count]u64 = std.mem.zeroes([command_count]u64),

    /// Elapsed time must be monotonic and supplied by the caller in us.
    /// Saturating additions prevent counter rollover after long runtimes.
    pub fn record(self: *Recorder, command: Command, outcome: Outcome, elapsed_us: u64) void {
        const c = @intFromEnum(command);
        const o = @intFromEnum(outcome);
        self.counts[c][o] +|= 1;
        self.total_duration_us[c] +|= elapsed_us;
        for (latency_buckets_us, 0..) |limit, i| {
            if (elapsed_us <= limit) {
                self.buckets[c][i] +|= 1;
                return;
            }
        }
        self.buckets[c][bucket_count - 1] +|= 1;
    }


    /// Caller-owned Prometheus exposition. Only compile-time command/outcome
    /// labels appear, never SQL, addresses, passwords, or server messages.
    pub fn formatPrometheus(self: *const Recorder, allocator: std.mem.Allocator) ![]u8 {
        var buffer: std.ArrayList(u8) = .empty;
        errdefer buffer.deinit(allocator);
        inline for (.{ Command.query, Command.prepared, Command.transaction, Command.ping, Command.session }) |command| {
            const c = @intFromEnum(command);
            inline for (.{ Outcome.success, Outcome.server_error, Outcome.timeout, Outcome.canceled, Outcome.transport_error, Outcome.client_error, Outcome.ambiguous }) |outcome| {
                const text = try std.fmt.allocPrint(allocator,
                    "zig_mysql_commands_total{{command=\"{s}\",outcome=\"{s}\"}} {d}\n",
                    .{ @tagName(command), @tagName(outcome), self.counts[c][@intFromEnum(outcome)] });
                defer allocator.free(text);
                try buffer.appendSlice(allocator, text);
            }
            var sum: u64 = 0;
            for (latency_buckets_us, 0..) |upper, i| {
                sum +|= self.buckets[c][i];
                const line = try std.fmt.allocPrint(allocator,
                    "zig_mysql_command_duration_us_bucket{{command=\"{s}\",le=\"{d}\"}} {d}\n",
                    .{ @tagName(command), upper, sum });
                defer allocator.free(line);
                try buffer.appendSlice(allocator, line);
            }
            sum +|= self.buckets[c][bucket_count - 1];
            const ending = try std.fmt.allocPrint(allocator,
                "zig_mysql_command_duration_us_bucket{{command=\"{s}\",le=\"+Inf\"}} {d}\n" ++
                "zig_mysql_command_duration_us_count{{command=\"{s}\"}} {d}\n" ++
                "zig_mysql_command_duration_us_sum{{command=\"{s}\"}} {d}\n",
                .{ @tagName(command), sum, @tagName(command), self.operations(command), @tagName(command), self.total_duration_us[c] });
            defer allocator.free(ending);
            try buffer.appendSlice(allocator, ending);
        }
        return buffer.toOwnedSlice(allocator);
    }


    /// Combine a worker-local accumulator into an independent snapshot.
    pub fn merge(self: *Recorder, other: *const Recorder) void {
        for (0..command_count) |c| {
            for (0..outcome_count) |o| self.counts[c][o] +|= other.counts[c][o];
            for (0..bucket_count) |i| self.buckets[c][i] +|= other.buckets[c][i];
            self.total_duration_us[c] +|= other.total_duration_us[c];
        }
    }

    pub fn operations(self: *const Recorder, command: Command) u64 {
        var total: u64 = 0;
        for (self.counts[@intFromEnum(command)]) |n| total +|= n;
        return total;
    }
};

test "fixed labels, inclusive bucket boundary and NULL-free counters" {
    var m: Recorder = .{};
    try std.testing.expectEqual(@as(u64, 0), m.operations(.query));
    m.record(.query, .success, 100);
    m.record(.query, .timeout, 101);
    m.record(.prepared, .server_error, 5_000_001);
    try std.testing.expectEqual(@as(u64, 2), m.operations(.query));
    try std.testing.expectEqual(@as(u64, 1), m.counts[@intFromEnum(Command.query)][@intFromEnum(Outcome.timeout)]);
    try std.testing.expectEqual(@as(u64, 1), m.buckets[@intFromEnum(Command.query)][0]);
    try std.testing.expectEqual(@as(u64, 1), m.buckets[@intFromEnum(Command.query)][1]);
    try std.testing.expectEqual(@as(u64, 1), m.buckets[@intFromEnum(Command.prepared)][bucket_count - 1]);
    try std.testing.expectEqual(@as(u64, 201), m.total_duration_us[@intFromEnum(Command.query)]);
}

test "counters saturate rather than overflow" {
    var m: Recorder = .{};
    const c = @intFromEnum(Command.transaction);
    const o = @intFromEnum(Outcome.ambiguous);
    m.counts[c][o] = std.math.maxInt(u64);
    m.total_duration_us[c] = std.math.maxInt(u64);
    m.record(.transaction, .ambiguous, 5);
    try std.testing.expectEqual(std.math.maxInt(u64), m.counts[c][o]);
    try std.testing.expectEqual(std.math.maxInt(u64), m.total_duration_us[c]);
}

test "Prometheus exposition uses fixed labels and cumulative buckets" {
    var m: Recorder = .{};
    m.record(.query, .success, 100);
    m.record(.query, .server_error, 101);
    const output = try m.formatPrometheus(std.testing.allocator);
    defer std.testing.allocator.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "command=\"query\",outcome=\"server_error\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "command=\"query\",le=\"100\"} 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "command=\"query\",le=\"250\"} 2") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "zig_mysql_command_duration_us_sum{command=\"query\"} 201") != null);
}


/// Optional shared accumulator. Recorders attached to a Client must remain
/// borrower-local; aggregate them here only after detaching, or publish a
/// synchronized snapshot. Never expose its inner Recorder for mutation.
pub const SharedRecorder = struct {
    mutex: std.Io.Mutex = .init,
    value: Recorder = .{},

    pub fn record(self: *SharedRecorder, io: std.Io, command: Command, outcome: Outcome, elapsed_us: u64) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value.record(command, outcome, elapsed_us);
    }

    pub fn merge(self: *SharedRecorder, io: std.Io, other: *const Recorder) void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        self.value.merge(other);
    }

    pub fn snapshot(self: *SharedRecorder, io: std.Io) Recorder {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        return self.value;
    }
};

test "merged telemetry saturates and preserves all outcome and bucket counts" {
    var lhs: Recorder = .{};
    var rhs: Recorder = .{};
    lhs.record(.query, .success, 100);
    rhs.record(.query, .timeout, 101);
    rhs.record(.ping, .success, 1000);
    lhs.merge(&rhs);
    try std.testing.expectEqual(@as(u64, 2), lhs.operations(.query));
    try std.testing.expectEqual(@as(u64, 1), lhs.operations(.ping));
    try std.testing.expectEqual(@as(u64, 201), lhs.total_duration_us[@intFromEnum(Command.query)]);
}
