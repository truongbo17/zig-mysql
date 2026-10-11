# Sprint B — Evidence and handoff (2026-10-11)

**Scope:** MySQL classic protocol result lifecycle. This engineering report does
**not** certify production-readiness; the OPS release epic #13 remains open.

## Delivered changes

| Ticket | Implementation / evidence |
| --- | --- |
| [#20](https://github.com/truongbo17/zig-mysql/issues/20) — B1 | [PR #52](https://github.com/truongbo17/zig-mysql/pull/52); [Zig 0.16/0.17 CI](https://github.com/truongbo17/zig-mysql/actions/runs/38116572202); negotiated multi-result framing, safe draining, empty rows and later errors |
| [#21](https://github.com/truongbo17/zig-mysql/issues/21) — B2 | [PR #53](https://github.com/truongbo17/zig-mysql/pull/53); [Zig 0.16/0.17 CI](https://github.com/truongbo17/zig-mysql/actions/runs/38134684623); CALL result iteration, final OK, IN/OUT/INOUT, timeouts and cancellation |
| [#22](https://github.com/truongbo17/zig-mysql/issues/22) — B3 | [PR #54](https://github.com/truongbo17/zig-mysql/pull/54); [Zig 0.16/0.17 CI](https://github.com/truongbo17/zig-mysql/actions/runs/38135291250); prepared binary per-row streaming, NULL/BLOB preservation, draining and parser hardening |
| [#23](https://github.com/truongbo17/zig-mysql/issues/23) — B4 | [PR #55](https://github.com/truongbo17/zig-mysql/pull/55); [Zig 0.16/0.17 CI PASS](https://github.com/truongbo17/zig-mysql/actions/runs/38135757213); 101k-row fixed-memory scan, >16 MiB binary packet, KILL and timeout/pool recovery |

## B4 reproducible test evidence

- 101,000 prepared binary rows scanned on MySQL 8.0 and MariaDB with **a
  fixed 2,097,152-byte client allocator**, which prevents the driver from
  accumulating the complete resultset in memory during this test.
- Prepared MySQL `SELECT REPEAT('Z', 16777216)` verifies one row
  crossing the 16,777,215-byte classic-packet boundary.
- `KILL CONNECTION` during a long prepared stream verifies that the
  desynchronized connection is evicted, `Pool.stats().in_use == 0`, and
  replacement checkout/ping succeeds with `max_open=1`.
- A 50 ms timeout against prepared `SLEEP(2)` verifies cancellation
  poison and pool recovery on MySQL and MariaDB.
- Full Zig 0.16 and 0.17 MySQL/MariaDB integration: [staging run
  #38135325228](https://github.com/truongbo17/zig-mysql/actions/runs/38135325228).
  All jobs passed on the original source/test implementation; the final
  B4 integration changes also passed [PR CI #38135757213](https://github.com/truongbo17/zig-mysql/actions/runs/38135757213).
  Any subsequent documentation commit must also pass CI before merge.

### Diagnostic throughput on GitHub Actions runners

The test prints `B4_STREAM_BENCH` with row count, elapsed nanoseconds,
rows/second and the fixed allocator capacity. Recorded from the **staging
run** above:

| Zig | Observed 101k-row rate (rows/sec) |
| --- | ---: |
| 0.16.0 | 239,393–239,882 |
| 0.17.0 | 321,828–335,088 |

These are **not** apples-to-apples performance comparisons or SLA claims:
runner noise, server workloads, cache and scheduling affect results. They
do not establish p50/p95/p99, stable RSS/FDs or throughput at 32–128 CCU.

## Remaining release blockers (OPS #13)

The independent production gate still requires a real, uninterrupted
24-hour single-process soak on both Zig versions, calibrated RSS/FD
resource budgets, trusted artifact provenance, representative p50/p95/p99
and CCU tests, real HA/fencing and network-partition drills, TLS rotation,
security review, deployment rollback and authorized release approval.
See [Production Readiness](PRODUCTION_READINESS.md) and
[Release Runbook](RELEASE_RUNBOOK.md). Never close #13 based solely on
Sprint B test CI.
