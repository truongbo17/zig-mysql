# zig-mysql — Feature Roadmap After Production Hardening

**Baseline:** Zig 0.16.0 and 0.17.0; verified TLS on Linux/macOS,
MySQL 8.0/8.4/9.x, MariaDB 10.11/11.4; classic protocol, text SQL,
prepared SQL, transactions, streaming text rows, bounded pool, writer guard,
connection failover and operational counters.

**Release status:** Staging-ready beta, not production-certified. Feature
development may proceed independently, but a real uninterrupted 24-hour soak,
representative HA/security checks and approved release controls are still
mandatory before production acceptance.

## How to track the work

**Canonical per-issue tracker:** [README Feature Plan](../README.md#feature-plan-and-issue-tracker). Every scope below has its own actionable GitHub ticket; do not interpret a roadmap entry as implemented until the linked child issue's PR is merged and exact-head CI is green. Update README status in that same PR. Parent epics remain open until all children are done.

- **Sprint A, type fidelity (P0):** [epic #10](https://github.com/truongbo17/zig-mysql/issues/10): [#14 audit](https://github.com/truongbo17/zig-mysql/issues/14) → [#15 DECIMAL](https://github.com/truongbo17/zig-mysql/issues/15), [#16 time/date](https://github.com/truongbo17/zig-mysql/issues/16), [#17 JSON/BLOB](https://github.com/truongbo17/zig-mysql/issues/17). [Epic #11](https://github.com/truongbo17/zig-mysql/issues/11): [#18 text scan](https://github.com/truongbo17/zig-mysql/issues/18) → [#19 binary scan](https://github.com/truongbo17/zig-mysql/issues/19).
- **Sprint B, resultsets (P1):** [epic #12](https://github.com/truongbo17/zig-mysql/issues/12): [#20 multi-result lifecycle](https://github.com/truongbo17/zig-mysql/issues/20) → [#21 CALL](https://github.com/truongbo17/zig-mysql/issues/21), [#22 prepared streaming](https://github.com/truongbo17/zig-mysql/issues/22) → [#23 robustness and large payloads](https://github.com/truongbo17/zig-mysql/issues/23).
- **Sprint C, transactions/cache (P1):** [#24 savepoints](https://github.com/truongbo17/zig-mysql/issues/24) → [#25 commit/cancel safety](https://github.com/truongbo17/zig-mysql/issues/25); after #20, [#26 statement cache](https://github.com/truongbo17/zig-mysql/issues/26) → [#27 cache benchmarks](https://github.com/truongbo17/zig-mysql/issues/27).
- **Sprint D, performance (P2):** [#28 metrics hooks](https://github.com/truongbo17/zig-mysql/issues/28), [#29 batch execution](https://github.com/truongbo17/zig-mysql/issues/29), [#30 TLS readiness](https://github.com/truongbo17/zig-mysql/issues/30) → [#31 high-CCU benchmark](https://github.com/truongbo17/zig-mysql/issues/31).
- **Sprint E, compatibility (P3):** [#32 charsets/SQL modes](https://github.com/truongbo17/zig-mysql/issues/32), [#33 protocol fuzz/large payloads](https://github.com/truongbo17/zig-mysql/issues/33), [#34 IPv6/Windows](https://github.com/truongbo17/zig-mysql/issues/34).
- **Parallel, production gates (not passed):** [epic #13](https://github.com/truongbo17/zig-mysql/issues/13): [#35 staging setup](https://github.com/truongbo17/zig-mysql/issues/35) → [#36 real 24h soak](https://github.com/truongbo17/zig-mysql/issues/36); [#37 workload and HA/security](https://github.com/truongbo17/zig-mysql/issues/37); [#38 trusted release provenance](https://github.com/truongbo17/zig-mysql/issues/38).

Start **#14**. Size each feature PR so tests, docs and a code review can complete independently. Avoid bundling Sprint A type changes and unrelated operational changes into one PR.

## Ranked feature backlog

| Priority | Feature | Business value | Acceptance evidence |
| --- | --- | --- | --- |
| P0 / next | Typed SQL values: lossless DECIMAL, DATE/TIME/DATETIME/TIMESTAMP, JSON, BLOB and nullable types | Financial and business data correctness | Round-trip native prepared binding and decoding on MySQL/MariaDB, monetary precision and timezone boundary tests |
| P0 / next | Typed row scanning API, preserving existing raw-row API | Safe ergonomic Go-like scanning in Zig | Explicit NULL/type mismatch/overflow behavior and documented ownership across Zig versions |
| P1 | Multi-resultsets and stored procedure response framing | Correct stored procedure and multi-result support | CALL, multiple OK/rows, later-result error, safe drain, malformed framing tests |
| P1 | Streaming prepared/binary resultsets | Support very large prepared SELECT with bounded memory | 100k+ rows, huge BLOB, per-row deadline and mid-stream disconnect with pool eviction |
| P1 | Transaction helpers and savepoints | Safer business transaction composition | Timeout-bounded COMMIT/ROLLBACK, savepoint lifecycle, ambiguous commit never retried |
| P1 | Per-connection bounded prepared-statement cache (optional) | Reduce repeated prepare network round trips | LRU limit, reset invalidation, COM_STMT_CLOSE, no server handle leak, p95 comparison |
| P2 | Per-command metrics and tracing hooks | Diagnose latency and saturation | Histogram, safe SQL redaction, no sensitive parameter labels, disabled overhead benchmark |
| P2 | Batch prepared execution / bulk inserts | Higher import and sync throughput | Packet and parameter bounds, partial failures, measured batch vs single-query throughput |
| P2 | Native event-loop readiness for TLS | Lower CPU vs current 1ms WANT_READ/WRITE sleeps | Cancellation-safe OpenSSL, latency/CPU baseline and bounded load test |
| P3 | Platform and protocol compatibility | Broader deployments | IPv6, Windows TLS, charset/collation/SQL modes, >16 MiB prepared results, fuzz coverage |

## Delivery order

### Sprint A — Type fidelity first
Audit current prepared Param, binary decode, text result parsing and column
metadata. Add opt-in Zig types and lossless decoding for decimal, time and
binary data. Real fixtures: Vietnamese UTF-8, NULL, zero bytes, large JSON,
high-precision accounting values, leap days, timezone/DST and overflows.
Acceptance: no silent precision loss, unexpected allocations or row lifetime
violations. Preserve the existing low-level API.

### Sprint B — Result lifecycle and streaming
Implement protocol-correct multi-result and stored procedure framing before
introducing caches. Add binary prepared row streams and explicit drain/abandon
semantics. Prove stable allocations during 100k-row selects and fail-closed
behavior on cancellation or disconnected servers.

### Sprint C — Transactions and statement cache
Add explicit transaction/savepoint helpers; no replay of failed writes or
ambiguous COMMIT. Implement optional per-connection LRU statement caching only
after session-reset invalidation, close semantics and pool-borrower isolation
are well tested. Compare latency against cache disabled.

### Sprint D — High concurrency / diagnostics
Instrument per-command error rates and p50/p95/p99 without SQL literals or
passwords in logs. Profile 1, 8, 32, 64 and 128 workers, including verified
TLS. Replace the OpenSSL 1ms sleep retry only with evidence-based native I/O
readiness and confirm CPU/latency improvements without correctness regressions.

## Excluded from the initial driver scope

Full ORM, schema migrations and query builders (separate higher-level
packages). Transparent retries of writes/COMMIT, unsafe failover to stale
replicas or exactly-once semantics. LOCAL INFILE remains disabled unless a
separately reviewed security design warrants changing it.

## Definition of done for every feature

1. Reviewed API contract, ownership/lifetime, timeout and error semantics.
2. Unit, malformed/fault and real MySQL/MariaDB integration evidence.
3. Exact-head CI green on Zig 0.16 and 0.17.
4. Reproducible benchmark for performance claims.
5. Updated examples/README and compatibility notes.
