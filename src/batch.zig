const std = @import("std");
const mysql = @import("client.zig");
const temporal = @import("temporal.zig");
const Decimal = @import("decimal.zig").Decimal;

/// A bounded sequence of COM_STMT_EXECUTE calls on an existing prepared DML
/// statement. One row = one execute, not a multi-values SQL rewrite.
pub const Options = struct {
    max_rows: usize = 1_000,
    /// Limit for each encoded COM_STMT_EXECUTE payload, not total batch.
    /// The driver's connection max_message_size may impose a tighter limit.
    max_packet_bytes: usize = 1024 * 1024,
};

/// Updated only after a fully acknowledged successful execute. On transport
/// failure later statement outcomes can be unknown, even when completed is
/// smaller. The caller owns transaction/rollback/reconciliation.
pub const Progress = struct {
    completed: usize = 0,
    affected_rows: u64 = 0,
    last_insert_id: u64 = 0,
};

fn addSize(total: *usize, amount: usize, budget: usize) !void {
    total.* = std.math.add(usize, total.*, amount) catch return error.BatchPacketTooLarge;
    if (total.* > budget) return error.BatchPacketTooLarge;
}

fn lengthPrefix(n: usize) usize {
    if (n < 251) return 1;
    if (n <= 0xffff) return 3;
    if (n <= 0xffffff) return 4;
    return 9;
}

/// Preflight exact wire payload size and parameter validations with no I/O.
pub fn validateRow(statement: mysql.Statement, params: []const mysql.Param, budget: usize) !void {
    if (statement.closed) return error.StatementClosed;
    if (statement.column_count != 0) return error.BatchRequiresDmlStatement;
    if (params.len != statement.parameter_count) return error.ParameterCountMismatch;
    if (budget < 10) return error.BatchPacketTooLarge;
    var bytes: usize = 10; // COM_STMT_EXECUTE id, cursor flags and iterations.
    if (params.len > 0) {
        try addSize(&bytes, (params.len + 7) / 8, budget);
        try addSize(&bytes, 1, budget); // new-parameter-bound flag
        try addSize(&bytes, std.math.mul(usize, params.len, 2) catch return error.BatchPacketTooLarge, budget);
    }
    for (params) |param| switch (param) {
        .null => {},
        .int, .uint, .float => try addSize(&bytes, 8, budget),
        .boolean => try addSize(&bytes, 1, budget),
        .date => |v| {
            try temporal.validateDate(v);
            try addSize(&bytes, 5, budget);
        },
        .datetime, .timestamp => |v| {
            try temporal.validateDateTime(v);
            try addSize(&bytes, if (v.microsecond == 0) 8 else 12, budget);
        },
        .time => |v| {
            try temporal.validateTime(v);
            try addSize(&bytes, if (v.microsecond == 0) 9 else 13, budget);
        },
        .decimal => |v| {
            _ = try Decimal.parse(v);
            try addSize(&bytes, lengthPrefix(v.len), budget);
            try addSize(&bytes, v.len, budget);
        },
        .text, .bytes => |v| {
            try addSize(&bytes, lengthPrefix(v.len), budget);
            try addSize(&bytes, v.len, budget);
        },
    };
}

/// Execute a bounded, prevalidated batch. Never creates or commits a
/// transaction. A later server error leaves earlier successful statements
/// applied unless the caller explicitly ROLLBACKs an enclosing transaction.
/// No automatic retries (especially after transport errors).
pub fn execute(
    connection: *mysql.Client,
    io: std.Io,
    statement: mysql.Statement,
    rows: []const []const mysql.Param,
    progress: *Progress,
    options: Options,
) !void {
    progress.* = .{};
    if (options.max_rows == 0 or options.max_packet_bytes == 0) return error.InvalidBatchOptions;
    if (rows.len > options.max_rows) return error.BatchTooManyRows;
    // Validate the entire batch before its first write to avoid deterministic
    // local validation failures after earlier rows have been applied.
    const effective_budget = @min(options.max_packet_bytes, connection.wire.max_message_size);
    for (rows) |row| try validateRow(statement, row, effective_budget);
    for (rows) |row| {
        var result = try connection.execute(io, statement, row);
        defer result.deinit();
        if (result.value != .ok) return error.BatchUnexpectedResult;
        progress.completed += 1;
        progress.affected_rows +|= result.value.ok.affected_rows;
        progress.last_insert_id = result.value.ok.last_insert_id;
    }
}

test "preflight validates every row, packet bytes and statement kind" {
    const stmt: mysql.Statement = .{ .id = 1, .parameter_count = 2, .column_count = 0 };
    try validateRow(stmt, &.{ .{ .int = 1 }, .{ .text = "hi" } }, 10 + 1 + 1 + 4 + 8 + 1 + 2);
    try std.testing.expectError(error.BatchPacketTooLarge,
        validateRow(stmt, &.{ .{ .int = 1 }, .{ .text = "hi" } }, 10));
    try std.testing.expectError(error.ParameterCountMismatch,
        validateRow(stmt, &.{.{ .int = 1 }}, 100));
    var select = stmt;
    select.column_count = 1;
    try std.testing.expectError(error.BatchRequiresDmlStatement,
        validateRow(select, &.{ .{ .int = 1 }, .{ .text = "hi" } }, 100));
    try std.testing.expectError(error.BatchPacketTooLarge,
        validateRow(stmt, &.{ .{ .int = 1 }, .{ .bytes = "payload" } }, 20));
}
