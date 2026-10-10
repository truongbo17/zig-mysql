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

## Ordered connection failover

`PoolConfig.failover_addresses` allows ordered fallback **only when a new
connection cannot be established**. Every connection attempt (primary and
fallback) uses `connect_attempt_timeout`, which defaults to five seconds
and includes authentication and TLS handshake. Each candidate address must
lead to an equivalent, correctly configured MySQL node with the same role,
database, permissions and expected TLS certificate identity.

```zig
var pool = try mysql.Pool.init(allocator, .{
    .connection = .{
        .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("10.0.0.1:3306") },
        .username = "app",
        .password = password,
        .database = "app_db",
        .tls = .{ .host = "mysql.internal", .ca_file = "/etc/mysql-ca.pem" },
    },
    .failover_addresses = &.{
        .{ .ip = try std.Io.net.IpAddress.parseLiteral("10.0.0.2:3306") },
    },
    .connect_attempt_timeout = .fromSeconds(3),
    .require_writable = true, // reject a replica still in read_only=ON mode
    .max_open = 10,
    .max_idle = 10,
});
defer pool.deinit(io);
```

**This is connection-establishment failover, not transparent query failover.**
Authentication denial, incompatible security policy, invalid TLS certificates,
and invalid client configuration fail closed: they are not treated as a reason
to try alternate endpoints. Only transport/connection setup failures trigger
ordered fallback. The pool does not re-run SQL commands, resume transactions, detect replication
lag or guarantee that a failed write was not committed. If an existing
connection dies during a transaction, return/discard it and let application
transaction and idempotency policy decide whether the operation may be retried.
Idle sockets remain bound to their connected server until evicted; fallback
will be considered only for new connections. For write-capable pools,
`require_writable=true` checks `SELECT @@global.read_only` on every new
connection and each idle checkout. Read-only candidates are closed and
rejected; other eligible endpoints can be attempted at connection setup.
It prevents accidental checkout of a demoted read-only node, but **is not a
distributed writer lease**: promotion, fencing, quorum, split-brain prevention,
replica lag, and transaction outcomes still require external HA orchestration.
Do not set `validate_on_acquire=false` and assume it disables this writer
check; the writer check is enforced separately.

## Operational pool telemetry

`pool.stats(io)` returns a consistent, mutex-protected snapshot of
`open`, `idle`, `in_use`, plus cumulative counters:
`health_check_failures`, `expired_connections`, `connections_created`,
`connections_closed`, `waits`, `acquire_timeouts`,
`connect_failures`, `reset_failures`, `failover_attempts`,
`failover_successes`, and `read_only_rejections`. The built-in, label-free Prometheus text formatter
can be used in your application's existing metrics HTTP endpoint:

```zig
const snapshot = pool.stats(io);
const metrics = try snapshot.formatPrometheus(allocator);
defer allocator.free(metrics);
// Send metrics bytes in your existing /metrics handler.
```

The library does not start an HTTP listener or configure scraping/alerts.
Counters are process-local and reset on restart. Monitor error/timeout
**rates**, pool saturation and stale-session evictions; avoid logging database
credentials or exposing user-controlled strings as metrics labels.

## Fault-injection and soak testing

`bash integration/run.sh` starts disposable MySQL and MariaDB instances,
exercises tests, benchmarks, and a brief repeated stress smoke. It also uses
two Python loopback fixtures to simulate silent MySQL greeting and stalled
TLS ServerHello, and restarts the MySQL 8.0 container to exercise
reconnection. The soak helper `bash integration/soak.sh <seconds>` now keeps **one Zig
process and one pool** alive across the entire run. It repeatedly drives 16
borrowers against eight pooled connections, checks counters after every
round, and logs completed operations. `bash integration/soak.sh 86400` runs
a 24-hour acceptance workload against a **running test MySQL** on port 33306.
On Linux, the soak wrapper observes the inner Zig test process under
`/proc` and prints a `SOAK_RESOURCE_SUMMARY` JSON record: first/last/peak
RSS (KiB), open file-descriptor counts, samples and duration. Optional
`SOAK_METRICS_PATH=/tmp/soak.json`, `SOAK_MAX_RSS_KB=...` and
`SOAK_MAX_FDS=...` enable evidence retention and absolute resource budgets.
Short CI smoke results do **not** prove 24-hour uptime or memory leak absence.
`bash integration/replication_run.sh` starts actual MySQL 8.0 primary/replica
instances, waits for binlog replication of a marker, asserts that writer-only
pool rejects the read-only replica, then manually stops/fences the primary,
promotes the replica, and verifies the marker and a successful post-promotion
write. This is a controlled promotion drill, **not** production HA certification
or an automated split-brain-safe failover controller. The independent
stress suite additionally uses 32 borrowers and injected KILL CONNECTIONs.

## Network partitions and release evidence

The real MySQL replication drill now also injects a **Docker network
partition** while the primary remains running: it commits a transaction
on the isolated primary, verifies the read-only replica has not received
it and rejects writer checkout, then heals the network. It **refuses
promotion until the missing transaction is replicated**, then fences
the old primary before manually promoting the replica.

```bash
bash integration/replication_run.sh
```

This guards the particular stale-replica promotion scenario but is **not**
automatic HA, split-brain fencing or a server-side durability guarantee.

Production soak evidence uses a fail-closed offline gate, with a pinned Git
SHA, single-process 24-hour duration, an observed RSS/FD sampling span, and
versioned resource budgets:

```bash
SOAK_METRICS_PATH=/tmp/zig-mysql-soak.json bash integration/soak.sh 86400
python3 integration/release_gate.py \
  --report /tmp/zig-mysql-soak.json \
  --policy docs/production-soak-policy.json \
  --expected-sha "$(git rev-parse HEAD)"
```

A CI smoke report of only 12 seconds **must fail** the release gate.
The checker does not independently validate GitHub checks or attest report
integrity. Consult the [production release runbook](docs/RELEASE_RUNBOOK.md)
before considering a critical production deployment. A real 24-hour soak
and independently reviewed network/security operating controls are still
outstanding.

## Dedicated 24-hour staging acceptance workflow

A new manual GitHub Actions workflow, [Staging 24h Soak](.github/workflows/staging-soak.yml),
runs the single Zig pool test for 24 hours on a **dedicated self-hosted Linux
runner** (label: zig-mysql-soak). It targets only an isolated nonproduction
MySQL server supplied via GitHub environment variables/secrets, not the
default disposable CI fixture. The production-soak gate enforces a full
sample interval, fixed Git SHA, successful Zig workload completion with SQL
operation totals, bounded RSS and FDs, and the configured version-controlled
resource budgets. JSON evidence is retained as an Actions artifact.

The runner, protected approval environment and isolated MySQL server
must be provisioned before the manual workflow can execute. **No 24-hour
workflow has been run yet**, and the job does not publish a release or assert
global production readiness. A 12-second CI smoke still fails the production
gate as intended. See the [release runbook](docs/RELEASE_RUNBOOK.md).

## Feature plan and issue tracker

This is the **canonical README checklist** for the next driver features.
[Detailed design and acceptance roadmap](docs/FEATURE_ROADMAP.md) contains
the technical rationale; GitHub issues contain per-PR acceptance checklists.
**Statuses below are planned**, not implemented, until a linked issue has
passed exact-commit CI and its PR has been merged. A feature CI success is
not a production certification. Keep this table and the detailed roadmap
updated in the same PR that closes or reschedules an issue.

**Execution policy:** one small, backward-compatible feature per PR; dependencies
before dependents; Zig 0.16/0.17 tests plus real MySQL/MariaDB integration;
self-review; no merge when CI is red. Prioritize correctness and SQL data
fidelity before broadening APIs and chasing benchmarks.

### Sprint A — Lossless data types and typed row scanning (P0)

Epic trackers: [#10 SQL values](https://github.com/truongbo17/zig-mysql/issues/10)
and [#11 typed scanner](https://github.com/truongbo17/zig-mysql/issues/11).

| Order | Small issue (one PR each) | Dependency | Status |
| --- | --- | --- | --- |
| A0 | [#14 Audit type codes, parsers and row ownership](https://github.com/truongbo17/zig-mysql/issues/14) | — completed | Done — [PR #40](https://github.com/truongbo17/zig-mysql/pull/40) |
| A1 | [#15 Lossless DECIMAL/NEWDECIMAL](https://github.com/truongbo17/zig-mysql/issues/15) | #14 | Done — [PR #41](https://github.com/truongbo17/zig-mysql/pull/41) |
| A2 | [#16 DATE/TIME/DATETIME/TIMESTAMP](https://github.com/truongbo17/zig-mysql/issues/16) | #14 | Planned |
| A3 | [#17 JSON/BLOB/UTF-8 byte safety](https://github.com/truongbo17/zig-mysql/issues/17) | #14 | Planned |
| A4 | [#18 Typed scanner for text rows](https://github.com/truongbo17/zig-mysql/issues/18) | #14–#17 as applicable | Planned |
| A5 | [#19 Typed scanner for prepared binary rows](https://github.com/truongbo17/zig-mysql/issues/19) | #18 + scalar types | Planned |

### Lossless DECIMAL binding (A1)

`mysql.Decimal.parse(bytes)` validates a borrowed ASCII DECIMAL/NEWDECIMAL
lexical value without allocating or converting to floating point. It retains
the original digits, sign, precision (up to 65 digits) and scale (up to 30).
Invalid, NaN, exponent and out-of-range literals return explicit errors.

```zig
const amount = try mysql.Decimal.parse("12345678901234567890.12345678901234567890");
var result = try conn.execute(io, stmt, &.{.{ .decimal = amount.bytes }});
defer result.deinit();
```

`Param.decimal` validates locally **before any command packet is sent**,
then binds as MySQL `VAR_STRING` for server-side DECIMAL coercion.
A SELECT of `DECIMAL`/`NEWDECIMAL` is already available as exact ASCII
bytes in text and prepared result rows; parse those bytes with
`mysql.Decimal.parse` while the owning `Result` or `RowStream` is alive.
The destination column precision, scale and SQL mode remain authoritative:
the server may round or reject values according to schema/settings.
This is a decimal lexical API, not a base-10 arithmetic library.

### Sprint B — Correct resultset lifecycle and streaming (P1)

Epic tracker: [#12 Multiple results and prepared streaming](https://github.com/truongbo17/zig-mysql/issues/12).

| Order | Small issue | Dependency | Status |
| --- | --- | --- | --- |
| B1 | [#20 Multi-result framing and safe drain](https://github.com/truongbo17/zig-mysql/issues/20) | — first in Sprint B | Planned |
| B2 | [#21 Stored procedure CALL resultsets](https://github.com/truongbo17/zig-mysql/issues/21) | #20 | Planned |
| B3 | [#22 Prepared binary row streaming API](https://github.com/truongbo17/zig-mysql/issues/22) | #20 | Planned |
| B4 | [#23 100k rows, >16 MiB and streaming fault tests](https://github.com/truongbo17/zig-mysql/issues/23) | #22 | Planned |

### Sprint C — Transactions and prepared-statement cache (P1)

| Order | Small issue | Dependency | Status |
| --- | --- | --- | --- |
| C1 | [#24 Savepoints and transaction helpers](https://github.com/truongbo17/zig-mysql/issues/24) | Existing transaction API | Planned |
| C2 | [#25 Bounded COMMIT/ROLLBACK and ambiguous outcomes](https://github.com/truongbo17/zig-mysql/issues/25) | #24 contract | Planned |
| C3 | [#26 Per-connection bounded statement cache](https://github.com/truongbo17/zig-mysql/issues/26) | #20, reset safety | Planned |
| C4 | [#27 Cache benchmarks and regressions](https://github.com/truongbo17/zig-mysql/issues/27) | #26 | Planned |

### Sprint D — Observability, batching and high CCU (P2)

| Order | Small issue | Dependency | Status |
| --- | --- | --- | --- |
| D1 | [#28 Per-command metrics and latency hooks](https://github.com/truongbo17/zig-mysql/issues/28) | Existing Pool Stats | Planned |
| D2 | [#29 Safe batch prepared execute/bulk insert](https://github.com/truongbo17/zig-mysql/issues/29) | Sprint A prepared types | Planned |
| D3 | [#30 Native TLS readiness waits](https://github.com/truongbo17/zig-mysql/issues/30) | Cancellation safety | Planned |
| D4 | [#31 1–128 worker TLS/CCU benchmarks](https://github.com/truongbo17/zig-mysql/issues/31) | #28, #30 | Planned |

### Sprint E — Compatibility and protocol robustness (P3)

| Order | Small issue | Dependency | Status |
| --- | --- | --- | --- |
| E1 | [#32 Charset, collation and SQL-mode matrix](https://github.com/truongbo17/zig-mysql/issues/32) | Sprint A | Planned |
| E2 | [#33 Protocol fuzzing and >16 MiB prepared payloads](https://github.com/truongbo17/zig-mysql/issues/33) | Protocol/test fixtures | Planned |
| E3 | [#34 IPv6 and Windows portability evaluation](https://github.com/truongbo17/zig-mysql/issues/34) | Platform CI | Planned |

### Parallel production acceptance — NOT yet passed

Release blocker epic: [#13 Evidence-backed production acceptance](https://github.com/truongbo17/zig-mysql/issues/13).

| Order | Operational gate | Dependency | Status |
| --- | --- | --- | --- |
| OPS1 | [#35 Dedicated isolated staging runner and MySQL](https://github.com/truongbo17/zig-mysql/issues/35) | Runner and protected environment provisioning | Blocked — not verified |
| OPS2 | [#36 Real 24-hour soak, both Zig versions](https://github.com/truongbo17/zig-mysql/issues/36) | #35 | Blocked — not executed |
| OPS3 | [#37 Realistic workload, HA and security evaluation](https://github.com/truongbo17/zig-mysql/issues/37) | #35 | Planned — unverified |
| OPS4 | [#38 Required release checks and trusted provenance](https://github.com/truongbo17/zig-mysql/issues/38) | #36, #37 | Planned — release blocked |

A green 12-second smoke, a prepared 24-hour workflow or a manually promoted
replica is **not** proof of completed production acceptance. See
[release runbook](docs/RELEASE_RUNBOOK.md) and
[production-readiness gates](docs/PRODUCTION_READINESS.md).

**Next implementation:** [#14 — type/protocol audit](https://github.com/truongbo17/zig-mysql/issues/14).
Only proceed to #15–#17 after its API contract is reviewed. Feature PRs may
continue while the independent OPS release gate remains open.

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
