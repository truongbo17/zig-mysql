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
- OpenSSL verified TLS with CA and hostname validation; transport uses **nonblocking** file descriptors on Linux/macOS. The TLS retry path yields through cancelable Zig Io sleeps on WANT_READ/WRITE. Live tests must pass before accepting this as reliable.
- TCP/Unix and nonblocking TLS support cancellation-bound `queryWithTimeout`, `executeWithTimeout`, `pingWithTimeout`, `acquireWithTimeout` and streamed row deadlines.
- Session reset, bounded pool, health-check eviction, idle expiry and connection lifetime recycling.
- Streams must be closed before a connection is returned. Using a connection or statement after returning it is undefined caller behavior.

## Open production blockers

1. **TLS readiness and portability:** nonblocking OpenSSL now yields via 1 ms `std.Io` sleep during SSL_ERROR_WANT_READ/WRITE; verify successful TLS query deadlines and stalled ServerHello with CI. This is **not** event-loop-native readiness polling, Windows support, or proof against all pathological TLS peers. A full TLS transport security review is still necessary.
2. **Timeout cancellation vs server execution:** client abandonment **does not guarantee MySQL stopped a statement**. Non-idempotent writes require idempotency keys, transaction design and explicit retry policy.
3. **Observability and operational signals:** pool counters include created/closed sockets, waits, timeout, connect/reset errors, age/health eviction, and failover counts. Prometheus text formatting is available, but scrape endpoint, alerts, per-command I/O metrics, latency histograms, tracing integration and active transactions remain unverified.
4. **Fault matrix breadth:** deterministic silent greeting/TLS ServerHello, server restart, repeated connection KILL and ordered fallback on initial connect have automated suites. Intermittent packet loss, network partition, replicated-cluster failover, TLS disconnect under load, >16-MiB prepared results and a completed 24-hour RSS/CPU soak remain incomplete.
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

## New acceptance evidence to inspect

- **TLS deadline matrix:** `integration/tls_local.zig` checks real verified
  MySQL 8.4 TLS authentication, timed SELECT, SLEEP timeout, streaming and
  timed pool reuse. `integration/timeout_local.zig` with
  `integration/stall_server.py` checks deadline against silent MySQL greeting
  and TLS ServerHello.
- **Operational signals:** read `pool.stats(io)` for `open`, `idle`,
  `in_use`, `waits`, `acquire_timeouts`, `connect_failures`,
  `reset_failures`, `connections_created`, `connections_closed`,
  `expired_connections`, `health_check_failures`. Export and alert in
  your application; the library does not ship a metrics exporter.
- **Single-process soak:** `integration/soak.sh` retains one Zig process
  and one Pool, repeatedly exercising 16 concurrent borrowers with accounting
  assertions. This suite does not inject server-side KILL commands. The
  separate `stress-integration` suite uses 32 workers and killed sockets.
  A CI smoke (seconds) is not a completed 24-hour soak.
- **Restart:** `integration/run.sh` restarts its disposable MySQL 8.0
  container and runs the stress test again.

## Production hardening: failover and single-process soak

The latest changes introduce **connection-establishment-only failover**
(`PoolConfig.failover_addresses` and a per-endpoint
`connect_attempt_timeout`). Each endpoint must be equivalent in permissions,
schema, role, and TLS trust. Existing queries and transactions are **never
automatically replayed**: SQL may have committed before the transport failed,
so transactional retries must be managed and audited at the application layer.
The counters `failover_attempts` and `failover_successes` are now available
along with other pool metrics.

`Stats.formatPrometheus(allocator)` provides a label-free Prometheus text
snapshot for integration into an application's existing metrics endpoint.
This does not provide an HTTP server, actual scraping, alert rules, latency
histograms or paging. These still need deploying and verification.

The soak acceptance now uses `integration/soak_local.zig` in **one Zig process
with one retained Pool**, and `bash integration/soak.sh 86400` requests a
24-hour single-process run against an existing test MySQL on port 33306.
Each round checks active pool accounting and connection leak indicators.
The short CI invocation is only a smoke test. For production graduation
capture external RSS/CPU/file-descriptor trends, process restarts, a 24h
error/timeout tally and the full environment configuration.

A test that fails over from unreachable loopback addresses to the live
MySQL server proves ordered connection establishment; it is **not** evidence
of a replicated cluster failover with replication lag, fencing or promotion.
Network partition testing and failover drills on an actual replicated cluster
remain gates to be signed off separately.

## Replicated MySQL promotion drill and soak resource evidence

An optional `PoolConfig.require_writable=true` checks
`@@global.read_only=0` on every newly opened socket and idle checkout.
A candidate still read-only is closed rather than handed to a write-capable
application. This is **not** atomic fencing: leadership can change after
checkout and before a SQL write. HA promotion/fencing must remain external.

`integration/replication_run.sh` now provisions a **real** MySQL 8.0
primary and replica via binary-log file/position replication in two isolated
Docker instances. The drill verifies replication of a marker, rejects the
read-only replica, stops the original primary, manually detaches and promotes
the replica, then verifies existing replicated data and a new write through
an ordered fallback pool. This is stronger evidence than an unreachable-port
test, but it does **not** establish safe automatic election, semi-sync
durability, quorum fencing, replication lag SLO or partition behavior.

Linux `integration/soak.sh` now invokes `integration/soak_monitor.py` to
sample RSS and open file descriptors of the inner **single Zig test process**
from /proc. Inspect `SOAK_RESOURCE_SUMMARY` in CI. A short 12-second
smoke cannot prove the 24-hour RSS stability gate. For staging:
`SOAK_METRICS_PATH=/tmp/soak.json SOAK_MAX_RSS_KB=<budget>
SOAK_MAX_FDS=<budget> bash integration/soak.sh 86400`.
Set budgets based on expected application workload and representative
hardware; capture baseline, peak and final RSS/FDs, plus actual alerts.

## Partition / production-release evidence milestone

The Docker replication fixture now deliberately disconnects a still-running
writable source from its replica network, commits a transaction in isolation,
checks the read-only replica **does not** expose that transaction or accept
writer-only checkout, repairs the network and requires explicit replication
catch-up **before** fencing the source and manual promotion. This confirms a
specific partition and data-loss hazard is exercised. It does not confer
quorum, automatic failover, multi-zone fencing or split-brain protection.

The new [release runbook](RELEASE_RUNBOOK.md) and
`integration/release_gate.py` implement a **fail-closed structural check**
of a trusted soak report: >=24h observed resource sampling, exactly one test
process, matching full Git commit SHA, sufficient RSS/FD samples and configured
growth/peak budgets. The policy in
`docs/production-soak-policy.json` contains provisional budget thresholds
that must be calibrated to target hardware and application traffic.

CI now asserts that its 12-second smoke is **rejected** by this gate and
unit-tests tampered, missing, insufficient and resource-exceeding reports.
A real completed 24-hour soak still needs to be run separately; the checker
does not verify authenticity of JSON or live GitHub CI and must not itself
serve as a release authorization.

## Release decision

The test matrix establishes an evidence-backed **staging-ready beta**, not a
general production guarantee. To promote to production in a business-critical
service, require evidence from: a 24-hour soak on representative hardware,
TLS stall/latency/CPU profiling, real outage and failover drills, strict
connection leak checks, the complete charset/authentication workload matrix,
and operational metrics with pager thresholds.

Do not manufacture pass claims for criteria that are not yet instrumented,
run, or independently reviewed.
