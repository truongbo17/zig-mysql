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
| MariaDB | 10.11 / 11.4 | TCP authentication, prepared SQL, transactions and pool reset integration tested |

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
| Streaming metadata and per-row timeouts | TCP/Unix tested; TLS integration in CI |
| Server error code and SQLSTATE | Implemented |
| Multi-packet messages, including result rows over 16 MB | Implemented |
| Prepared statements, typed parameter binding, binary result rows | Implemented |
| Transactions (`begin`, `commit`, `rollback`) | Implemented |
| Session reset (`COM_RESET_CONNECTION`) and schema selection | Implemented |
| Bounded connection pool with waiting, session reset and broken-connection eviction | Implemented |
| Lazy idle expiry and max connection lifetime recycling | Implemented; live MySQL integration coverage |
| Idle health validation, optional PING deadline and reconnect on stale socket | Implemented |
| Buffered query and prepared execution deadlines | TCP/Unix tested; TLS integration in CI |
| Verified TLS with CA and hostname checks, full SHA2 authentication over TLS | Implemented (OpenSSL 3) |
| TCP connect timeout | Implemented |
| TLS handshake/query/stream deadlines | Nonblocking OpenSSL support; acceptance requires live TLS CI |

Unencrypted TCP does **not** send a cleartext password for full SHA2 authentication. Such a server request returns `error.SecureTransportRequired`. `LOCAL INFILE` is disabled. TLS uses nonblocking OpenSSL sockets with cancelable `std.Io` waits (`SSL_ERROR_WANT_READ`/`WANT_WRITE`); currently Linux/macOS only, with 1 ms retry granularity. This is not yet event-loop-native TLS readiness polling.

## Requirements

- Zig 0.16.0 or 0.17.0.
- OpenSSL 3 development/runtime libraries for the TLS backend. On macOS, the default prefix is `/opt/homebrew/opt/openssl@3`; override with `-Dopenssl_prefix=/your/prefix`.

## Build and test

```sh
zig build test
zig build integration  # requires the integration MySQL container on 127.0.0.1:33306
zig build stress-integration  # same MySQL server; concurrent pool fault injection
zig build timeout-integration  # with Python localhost stall fixtures on :33309/:33310
bash integration/soak.sh 86400  # optional 24-hour soak with running test MySQL
zig build mariadb-integration  # requires MariaDB test container on 127.0.0.1:33308
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
    .max_idle_time = .fromSeconds(60), // lazy eviction when next borrowed
    .max_connection_age = .fromSeconds(3600), // checked on return/borrow
    .validate_on_acquire = true, // default: COM_PING before reusing an idle socket
    .health_check_timeout = .fromSeconds(2), // default is 5s
    .session_reset_timeout = .fromSeconds(3), // default is 5s
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

A timed acquisition requires cancelable `std.Io` operations. TLS uses nonblocking OpenSSL. Timed acquisition works over TLS; it
cancels an incomplete handshake and cleans up the socket. The ordinary
`acquire(io)` and `tryAcquire(io)` remain available.
Unlike query timeouts, an acquisition timeout is not evidence that any SQL
has executed. Cancellation cleanup (including returning a connection acquired
at the deadline boundary) can make the method return slightly after the
configured duration; the limit is a cancellation deadline, not a hard
real-time latency guarantee.

A released connection is reset using MySQL `COM_RESET_CONNECTION` with a
bounded timeout by default, which rolls
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
connection) and can be disabled for latency-sensitive use. `health_check_timeout`
defaults to 5 seconds and bounds idle PING checks on TCP, Unix and TLS.
`session_reset_timeout` defaults to 5 seconds per cleanup command:
`COM_RESET_CONNECTION` and database restoration must both finish within
their respective deadlines or that socket is evicted. Set either value to
`null` only if unbounded cleanup I/O is intentional.

## TLS and end-to-end connection deadlines

`Client.connectWithTimeout(allocator, io, config, duration)` bounds TCP connect,
server greeting, TLS negotiation, certificate verification, authentication and
the complete initial MySQL handshake. It cleans up a half-open socket on
`error.ConnectTimeout`. `queryWithTimeout`, `executeWithTimeout`,
`pingWithTimeout`, `queryRowsWithTimeout` and `RowStream.nextWithTimeout`
also work over TLS with the current nonblocking OpenSSL backend.

```zig
var secure = try mysql.Client.connectWithTimeout(allocator, io, .{
    .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:3306") },
    .username = "app",
    .password = password,
    .database = "app",
    .tls = .{ .host = "db.example.com", .ca_file = "/etc/db-ca.pem" },
}, .fromSeconds(5));
defer secure.deinit(io);
var res = try secure.queryWithTimeout(io, "SELECT 1", .fromSeconds(2));
defer res.deinit();
```

The transport currently relies on a cancelable Zig `std.Io` wait after
OpenSSL `SSL_ERROR_WANT_READ` or `SSL_ERROR_WANT_WRITE`. Socket-level
nonblocking mode is enabled on Linux/macOS. Timeout and cancel semantics
require an `std.Io` runtime with working cancellation; closing a connection
remains mandatory after a timed-out SQL command. A TLS deadline is **not** a
server-side SQL execution limit. The 1 ms retry cadence may increase latency
and CPU use relative to native I/O readiness integration.

## Buffered query deadlines

The optional deadline methods race the entire operation against a monotonic
timer using `std.Io.Select`. They require a concurrent `std.Io` runtime and
a cancelable transport, including nonblocking OpenSSL TLS.
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
For streaming, `queryRowsWithTimeout(io, sql, duration)` bounds the
initial metadata phase; `RowStream.nextWithTimeout(io, duration)` applies a
fresh deadline to each row fetch. This is not a whole-stream deadline.
After a timeout, call `RowStream.deinit(io)`; it skips unsafe draining on
broken connections and the pool discards that socket. Streaming TLS traffic
supports the same per-row deadlines as TCP.
Timeout cancellation does not guarantee that the MySQL server has stopped
executing the SQL: avoid non-idempotent retries without application safeguards.

## Idle and lifetime recycling

Pool configuration can set `max_idle_time` and `max_connection_age`.
Both use the monotonic awake clock to avoid wall-clock adjustment issues.
Idle eviction is **lazy**: a socket is evicted when next checked out, not
by a background timer. Connection age is checked when returning to the pool
and when checked out; in-flight queries are not interrupted. Expired sessions
are counted in `pool.stats(io).expired_connections`. A zero duration expires
a connection at the next relevant boundary. This does not yet implement
periodic maintenance or a minimum-idle prewarm.

## Reliability and production gate

The CI suite now includes malformed-protocol parser cases, live streaming
timeout and session eviction tests, repeated concurrent operations with
`max_open=8`, server-side `KILL CONNECTION` fault injection, and MariaDB
10.11/11.4 interoperability runs. Successful CI must be verified per commit:
adding a test does not imply that the implementation passed it. See
[production readiness](docs/PRODUCTION_READINESS.md) for verified scope,
remaining risks and prerequisites before deploying to production.

## Operational pool telemetry

`pool.stats(io)` returns a consistent, mutex-protected snapshot with current
`open`, `idle`, `in_use`, plus cumulative:
`health_check_failures`, `expired_connections`, `connections_created`,
`connections_closed`, `waits`, `acquire_timeouts`,
`connect_failures`, and `reset_failures`. Export these through your
service metrics registry and alert on increasing acquire timeout, stale
session, reset failure and reconnect rates. These are process-local counters
and reset on process restart; no Prometheus exporter is bundled.

## Fault-injection and soak testing

`bash integration/run.sh` starts disposable MySQL and MariaDB instances,
exercises tests, benchmarks, and a brief repeated stress smoke. It also uses
two Python loopback fixtures to simulate silent MySQL greeting and stalled
TLS ServerHello, and restarts the MySQL 8.0 container to exercise
reconnection. The soak helper `bash integration/soak.sh <seconds>` repeats
the 32-worker, max-open-8 workload with five forcibly killed sessions per
iteration against a **running test MySQL** on port 33306. You can use
`86400` seconds for a separate 24-hour staging acceptance run; short CI
runs do **not** count as a completed 24-hour soak or memory-leak analysis.

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
