# zig-mysql

A native Zig client for the MySQL classic client/server protocol. The project is under active development; the API and compatibility claims below reflect tests that have actually run.

## About

`zig-mysql` is a Zig client library for the MySQL classic protocol. It supports TCP and Unix socket connections, authentication, verified TLS, text queries, prepared statements with typed parameters, transactions, a bounded connection pool, and buffered or streaming results. The wire protocol is implemented in Zig without the MySQL C client library; TLS uses OpenSSL 3. The compatibility table below lists the versions tested against real servers.

## Version Compatibility

| Component | Version | Status |
| --- | --- | --- |
| Zig | 0.17.0 | Unit and integration tests pass |
| Zig | 0.16.0 | Unit and integration tests pass |
| MySQL | 8.0.46 | TCP, native authentication, ping, text queries, results tested |
| MySQL | 8.4.11 | Unix socket and verified TLS, full caching SHA2 authentication, ping, prepared SELECT tested |
| MySQL | 9.7.1 | Unix socket, full caching SHA2 authentication, ping, prepared SELECT tested |
| MariaDB | 10.11 / 11.x | Planned integration test |

Compatibility is established by a real server test, rather than inferred from a version string. Server capabilities are negotiated during the handshake.

## Features

| Feature | Status |
| --- | --- |
| TCP, Unix socket and classic protocol handshake | Implemented |
| `mysql_native_password` | Implemented |
| `caching_sha2_password` fast and Unix socket full authentication | Implemented |
| Ping | Implemented |
| Text `COM_QUERY` including result rows and NULL | Implemented |
| Streaming text result rows, with drain on close | Implemented |
| Server error code and SQLSTATE | Implemented |
| Multi-packet messages, including result rows over 16 MB | Implemented |
| Prepared statements, typed parameter binding, binary result rows | Implemented |
| Transactions (`begin`, `commit`, `rollback`) | Implemented |
| Session reset (`COM_RESET_CONNECTION`) and schema selection | Implemented |
| Bounded connection pool with waiting, session reset and broken-connection eviction | Implemented |
| Idle health validation, optional PING deadline and reconnect on stale socket | Implemented |
| Buffered query and prepared execution deadlines (non-TLS TCP/Unix) | Implemented |
| Verified TLS with CA and hostname checks, full SHA2 authentication over TLS | Implemented (OpenSSL 3) |
| TCP connect timeout | Implemented |
| TLS query deadline and streaming row deadline | Planned |

Unencrypted TCP does **not** send a cleartext password for full SHA2 authentication. Such a server request returns `error.SecureTransportRequired`. `LOCAL INFILE` is disabled. TLS operations currently use blocking OpenSSL I/O, so timed query/execute/ping methods intentionally return `error.TimedTlsUnsupported` over TLS.

## Requirements

- Zig 0.16.0 or 0.17.0.
- OpenSSL 3 development/runtime libraries for the TLS backend. On macOS, the default prefix is `/opt/homebrew/opt/openssl@3`; override with `-Dopenssl_prefix=/your/prefix`.

## Build and test

```sh
zig build test
zig build integration  # requires the integration MySQL container on 127.0.0.1:33306
bash integration/run.sh  # disposable MySQL 8.0, 8.4 and 9.7 Docker matrix
zig build tls-integration  # requires local MySQL 8.4 on port 33307 and its CA at /tmp/zig-mysql-test-ca.pem
zig build bench  # separately run with the disposable MySQL 8.0 test container on port 33306
```

`zig build integration` expects a `zigtest` database and a `zigtest` user with password `zig_mysql_test` using `mysql_native_password`. `integration/run.sh` creates these test containers and cleans them up. These credentials are for disposable test servers only.

## Add as a Zig dependency

```sh
zig fetch --save git+https://github.com/truongbo17/zig-mysql#main
```

In `build.zig`, import `b.dependency("zig_mysql", .{}).module("zig_mysql")` into your application module. OpenSSL is linked by the package build module.

## Example

```zig
var threaded: std.Io.Threaded = .init(allocator, .{});
defer threaded.deinit();
const io = threaded.io();
var client = try mysql.Client.connect(allocator, io, .{
    .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:3306") },
    .username = "app",
    .password = password,
    .database = "app_db",
    .connect_timeout = .{ .duration = .fromSeconds(5) },
    .tls = .{ .host = "db.example.com", .ca_file = "/path/to/ca.pem" },
});
defer client.deinit(io);

var result = try client.query(io, "SELECT id, name FROM users");
defer result.deinit();
for (result.value.rows.items) |row| {
    // Values from the text protocol are nullable byte slices.
    _ = row;
}
```

Do not concatenate untrusted input into SQL. Use `prepare` and `execute` with typed parameters for input values.

For large `SELECT` results, use `queryRows` and call `RowStream.deinit(io)` after iteration. Each returned row's byte slices remain valid until the next `next(io)` call. A connection rejects other commands while streaming rows remain unread; `deinit` drains them so the connection can be reused.

## Connection pooling

`Pool` limits the number of live MySQL connections and waits when all connections
are checked out. Use `tryAcquire` to return `error.PoolExhausted` instead of
waiting. Every borrowed connection must be released exactly once.

```zig
var pool = try mysql.Pool.init(allocator, .{
    .connection = .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:3306") },
        .username = "app",
        .password = password,
        .database = "app_db",
    },
    .max_open = 10,
    .max_idle = 5,
    .validate_on_acquire = true, // default: COM_PING before reusing an idle socket
    .health_check_timeout = .fromSeconds(2), // non-TLS TCP/Unix only
});
defer pool.deinit(io);

const connection = try pool.acquire(io);
defer pool.release(io, connection);
var result = try connection.query(io, "SELECT 1");
defer result.deinit();
```

If callers must not wait indefinitely for an exhausted pool, use
`acquireWithTimeout(io, .fromMilliseconds(250))`. The timeout covers **the
whole acquisition**: waiting for a slot, checking an idle socket and opening
a replacement. Expiration returns `error.PoolAcquireTimeout`; the losing
acquisition is canceled and joined, so any connection acquired at the
deadline boundary is released rather than leaked. The implementation keeps
a slot reserved until an evicted connection is fully closed, enforcing the
configured `max_open` bound even when connections churn.

```zig
const connection = try pool.acquireWithTimeout(io, .fromMilliseconds(250));
defer pool.release(io, connection);
var result = try connection.queryWithTimeout(io, "SELECT 1", .fromSeconds(2));
defer result.deinit();
```

A timed acquisition requires cancelable `std.Io` operations. The OpenSSL
TLS backend currently blocks, so `acquireWithTimeout` returns
`error.TimedTlsUnsupported` when TLS is configured. The ordinary
`acquire(io)` and `tryAcquire(io)` remain available for TLS connections.
Unlike query timeouts, an acquisition timeout is not evidence that any SQL
has executed.

A released connection is reset using MySQL `COM_RESET_CONNECTION`, which rolls
back transactions, drops temporary tables, clears session variables and closes
prepared statements. The original database is selected again. Do not use
prepared statements, streams or a connection after returning it to the pool.
An active stream or broken connection is discarded instead of reused.

`Pool.deinit` requires all borrowers to have returned their connections and
must not race with `acquire` / `release`. The configuration's string slices
(including credentials and TLS settings) must outlive the pool. Provide a
thread-safe allocator for concurrent access. An idle connection that fails `COM_PING` will be destroyed and replaced,
and `stats(io).health_check_failures` exposes the number of discarded stale
sessions. Idle validation is on by default (one extra RTT on each reused
connection) and can be disabled for latency-sensitive use. A PING timeout is
optional; without it, a stalled health check may block. A non-null
`health_check_timeout` is rejected for TLS pools because OpenSSL currently
uses blocking I/O.

## Buffered query deadlines

The optional deadline methods race the entire operation against a monotonic
timer using `std.Io.Select`. They require a concurrent `std.Io` runtime and
a cancelable socket transport (plain TCP/Unix; TLS is not supported yet).
This covers fetching **all** buffered result rows, unlike server-side SELECT
execution-time hints. Expiration returns `error.QueryTimeout` and marks the
connection broken: it **must** be closed, never reset and reused, since MySQL
might still send the old response. A connection pool handles this eviction
automatically when you call `pool.release(io, connection)`.

```zig
const connection = try pool.acquire(io);
defer pool.release(io, connection);
var result = try connection.queryWithTimeout(
    io, "SELECT COUNT(*) FROM users", .fromSeconds(2),
);
defer result.deinit();
```

`executeWithTimeout(io, statement, params, duration)` covers prepared
statements; `pingWithTimeout(io, duration)` covers PING. The existing
`query`, `execute`, `queryRows` and transaction helpers remain unchanged.
No deadline is currently enforced for streaming row iteration or TLS traffic.
Timeout cancellation does not guarantee that the MySQL server has stopped
executing the SQL: avoid non-idempotent retries without application safeguards.

## Pool performance benchmark

With the disposable integration MySQL container listening on
`127.0.0.1:33306`, run `zig build -Doptimize=ReleaseFast bench`.
The reproducible workload executes `SELECT 1` using 1/8/32 concurrent
borrowers, with 200 queries per worker and a 16-connection limit. It compares
idle PING validation enabled vs disabled, reporting requests/second and
p50/p95/p99 total acquisition-to-release latency. This is a *local* benchmark,
not a general MySQL driver throughput claim; RTT, CPU, server config, and
pool reset/schema-selection commands affect measurements. The integration CI matrix runs the same workload and records diagnostic
measurements in GitHub Actions logs (not fixed performance guarantees).

## Protocol references

- [Packet framing](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html)
- [Connection phase](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html)
- [Text resultsets](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query_response_text_resultset.html)
- [Prepared statements](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_command_phase_ps.html)
- [Authentication](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_authentication_methods.html)
- [MySQL TLS exchange](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_tls.html)
- [OpenSSL hostname verification](https://docs.openssl.org/3.0/man3/SSL_set1_host/)

## License

MIT. See [LICENSE](LICENSE).
