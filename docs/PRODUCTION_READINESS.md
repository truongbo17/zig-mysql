# zig-mysql — Production Readiness Gate

This is an engineering acceptance document, **not a production certification**.

## Five hardening milestones

| ID | Deliverable | Acceptance evidence required |
| --- | --- | --- |
| M1 | Non-TLS streaming setup and per-row deadlines; poison timed-out socket; no draining a broken connection | Zig 0.16/0.17 CI + live `SELECT SLEEP` timeout and reconnect test |
| M2 | Malformed packet/cursor handling and connection poisoning | Unit and integration tests, packet desynchronization protection |
| M3 | Lazy idle timeout and max connection lifetime; no forced in-flight cancellation | Live MySQL session-id replacement tests + no connection leaks |
| M4 | MariaDB 10.11 and 11.4 interoperability | Disposable containers; prepared SQL, transactions and pool reset must pass both |
| M5 | Concurrent borrow/release and server-side socket fault injection | 32 workers × 100 operations, max_open=8, repeated KILL + automatic recovery; benchmark still runs |

**Do not mark a milestone PASS unless the exact head commit passes the corresponding CI jobs.**

## Current architecture / supported modes

- Zig 0.16/0.17 native classic-protocol client; MySQL 8.0/8.4/9.x matrix.
- OpenSSL verified TLS with CA and hostname validation; TLS operations remain **blocking**.
- Non-TLS TCP/Unix support cancellation-bound `queryWithTimeout`, `executeWithTimeout`, `pingWithTimeout`, `acquireWithTimeout` and streamed row deadlines.
- Session reset, bounded pool, health-check eviction, idle expiry and connection lifetime recycling.
- Streams must be closed before a connection is returned. Using a connection or statement after returning it is undefined caller behavior.

## Open production blockers

1. **Hard TLS I/O deadlines:** blocking OpenSSL read/write/handshake cannot be reliably cancelled via `std.Io.Select`. Application deadlines for TLS need a nonblocking OpenSSL transport integrated with I/O readiness and explicit tests for stalled server, zero-byte progress, and handshake timeouts.
2. **Timeout cancellation vs server execution:** client abandonment **does not guarantee MySQL stopped a statement**. Non-idempotent writes require idempotency keys, transaction design and explicit retry policy.
3. **Observability and operational signals:** counters beyond pool statistics are needed (timeouts, IO errors, reconnects, queue wait, active transactions), plus alert thresholds and tracing integration.
4. **Fault matrix breadth:** intermittent packet loss, server failover, TLS disconnect under load, network partitions, >16-MiB prepared results, sustained long-running workload and memory leak tests on representative infrastructure remain incomplete.
5. **Compatibility and security:** verify real workload/charset/SQL modes and authentication against deployed server versions, perform dependency review and run independent security assessment. MariaDB interoperability is tested only for cases in `integration/mariadb.zig`.

## Suggested production acceptance criteria

- Full green CI per target Zig and DB version; reproducible artifacts pinned to exact commits/images.
- 24-hour soak under expected concurrency and realistic payload sizes; no unbounded memory growth or leaked pool slots.
- Controlled fault injection: query cancellation, TCP reset, database restart, idle close and failover; no corrupted resultsets or reuse of a desynchronized connection.
- TLS connection, handshake and query deadline tests before exposing the driver to untrusted networks.
- Realistic load test comparing p50/p95/p99, throughput, reconnect rate and CPU/memory baseline.
- Clear application-side cancellation, retry, transaction and credential-rotation procedures.

## Useful commands

```sh
zig build test
bash integration/run.sh
# Individual tests require their disposable database fixtures:
zig build integration
zig build stress-integration
zig build mariadb-integration
zig build -Doptimize=ReleaseFast bench
```

The GitHub runner `SELECT 1` benchmarks are diagnostic and must **not** be treated as CCU or production SLA claims.
