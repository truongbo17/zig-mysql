# D2 — Bounded prepared DML batches (issue #29)

`mysql.Batch.execute(conn, io, statement, rows, &progress, options)`
executes a bounded array of parameter rows against **one already prepared DML
statement**. Each row uses one normal `COM_STMT_EXECUTE`; this is NOT a
multi-value INSERT, pipeline, server batch protocol or `LOCAL INFILE`.

## Safety and ownership

- All rows are locally prevalidated **before the first statement executes**,
  including type validation, parameter count, statement column count, and
  exact encoded payload bytes. Defaults: up to 1,000 rows; at most 1 MiB per
  prepared request. Caller may set smaller limits.
- No auto BEGIN, COMMIT, ROLLBACK, write retry, or database schema changes.
- Caller controls transaction scope. On a recoverable MySQL `ServerError`,
  `progress.completed` includes only previously acknowledged executions;
  caller should explicitly ROLLBACK before returning the connection.
- On transport errors or timeouts, the server may have performed unacknowledged
  writes. `progress.completed` is **not** authoritative for actual effects.
  Poisoned connections must be evicted and writes reconciled on a new session.
- This method handles DML whose prepared metadata has zero output columns;
  attempting to batch SELECT is rejected preflight.
- The API is deliberately sequential. It protects resource usage and makes
  partial failures explicit; do **not** claim it beats individual executes
  without benchmark evidence.

## Example

```zig
const rows = [_][]const mysql.Param{
    &.{ .{ .int = 1 }, .{ .text = "xin chào" } },
    &.{ .{ .int = 2 }, .{ .text = "hà nội" } },
};
var progress: mysql.Batch.Progress = .{};
try conn.begin(io);
mysql.Batch.execute(&conn, io, stmt, &rows, &progress, .{}) catch |err| {
    conn.rollback(io) catch {}; // transport failure may already be ambiguous
    return err;
};
try conn.commit(io);
```

Run `zig build -Doptimize=ReleaseFast batch-bench` with disposable MySQL 8.0
on port 33306 to compare exactly 256 single prepared executions against 256
prevalidated batched executions (still 256 round trips). No speedup is
assumed; printed rates are diagnostic, not a production SLA.

Acceptance pending: exact-head CI on Zig 0.16 and 0.17 with real MySQL and
MariaDB; packet-limit and preflight tests; measured benchmark evidence.
Production gate #13 remains OPEN.
