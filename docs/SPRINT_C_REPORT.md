# Sprint C — Transactions and prepared statement cache

Engineering evidence tracker. **Feature CI is not production certification.**
The independent [OPS #13](https://github.com/truongbo17/zig-mysql/issues/13)
remains open until real 24-hour soak, HA, security and release approval.

## Scope and evidence

| Feature | Issue | Evidence |
| --- | --- | --- |
| C1 — Nested savepoints and strict identifier validation | [#24](https://github.com/truongbo17/zig-mysql/issues/24) | [PR #56](https://github.com/truongbo17/zig-mysql/pull/56), [Zig 0.16/0.17 CI](https://github.com/truongbo17/zig-mysql/actions/runs/38141738935) |
| C2 — Bounded COMMIT/ROLLBACK and unknown outcomes | [#25](https://github.com/truongbo17/zig-mysql/issues/25) | [PR #57](https://github.com/truongbo17/zig-mysql/pull/57), [final CI PASS](https://github.com/truongbo17/zig-mysql/actions/runs/38142540809) |
| C3 — Opt-in per-connection LRU with reset/schema invalidation | [#26](https://github.com/truongbo17/zig-mysql/issues/26) | [PR #58](https://github.com/truongbo17/zig-mysql/pull/58), [final CI PASS](https://github.com/truongbo17/zig-mysql/actions/runs/38143171954) |
| C4 — Cache off/on and regression benchmarking | [#27](https://github.com/truongbo17/zig-mysql/issues/27) | [PR #59](https://github.com/truongbo17/zig-mysql/pull/59), [staging full CI PASS](https://github.com/truongbo17/zig-mysql/actions/runs/38142640379), final exact-head PR CI required before merge |

## Reproducing C4

Build and run the benchmark against the disposable MySQL 8.0 fixture on
`127.0.0.1:33306`, installed and torn down by `integration/run.sh`:

```sh
zig build -Doptimize=ReleaseFast cache-bench
```

- Same pinned mix of eight prepared `SELECT ? + N` statements,
  each with a positional binary-bound parameter.
- Cache OFF: explicit prepare/execute/close per request.
  Cache ON: bounded per-session LRU with capacity 16.
- Three worker levels: **1, 8, 32**, 200 requests/worker, pool max 16.
- Each worker holds one connection for its timed sequence. This
  measures intra-session reuse and avoids hiding all cache benefits
  behind pool reset between requests; it does **not** represent a
  transaction-per-HTTP-request pool workload.
- Print `CACHE_BENCH` key/value records with rate, p50/p95/p99 in ms,
  process CPU milliseconds (Linux POSIX `clock()`), cache hit/miss/
  eviction deltas and server `Com_stmt_prepare` counter deltas and
  `Prepared_stmt_count` gauge.
- OFF and ON are measured sequentially; the generated numbers vary
  by runner and cannot establish a relative production improvement
  without repeated dedicated-runner baselines and confidence
  intervals. The server counters are global and assume an isolated
  CI MySQL test instance.
- Cached server handles must close on LRU eviction and be invalidated
  by COM_RESET_CONNECTION, database switch or reconnection. The
  pool intentionally clears entries at borrower release; no
  cross-tenant/cross-borrower cache-sharing behavior is allowed.

## Production blockers

Full acceptance still requires dedicated hardware, uninterrupted
24-hour tests on both Zig versions, representative CCU and varied SQL,
stable RSS/FD and CPU budgets, p95/p99 across restarts and network
faults, secure transport validation, HA fencing and signed release
approval. See [Production Readiness](PRODUCTION_READINESS.md).

## C4 observed staging CI (2026-10-11)

[Full Zig 0.16/0.17 MySQL/MariaDB CI run #38142640379](https://github.com/truongbo17/zig-mysql/actions/runs/38142640379)
passed with the cache benchmark on the staging branch. Every
`CACHE_BENCH` line includes all tracked fields; the compact table
below records the measured values from the CI logs.

| Zig | Workers | Cache | Req/s | p50 ms | p95 ms | p99 ms | CPU ms | Cache hits / misses | Server prepares |
| --- | ---: | --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| 0.16.0 | 1 | OFF | 24.4 | 40.995 | 41.117 | 41.170 | 23.106 | 0 / 0 | 200 |
| 0.16.0 | 1 | ON | 5,619.8 | 0.168 | 0.177 | 0.310 | 9.902 | 192 / 8 | 8 |
| 0.16.0 | 8 | OFF | 194.8 | 41.000 | 41.127 | 41.932 | 167.698 | 0 / 0 | 1,600 |
| 0.16.0 | 8 | ON | 22,239.4 | 0.306 | 0.594 | 0.822 | 70.251 | 1,536 / 64 | 64 |
| 0.16.0 | 32 | OFF | 389.7 | 41.001 | 41.175 | 41.925 | 651.167 | 0 / 0 | 6,400 |
| 0.16.0 | 32 | ON | 26,942.7 | 0.499 | 1.069 | 1.646 | 275.408 | 6,144 / 256 | 256 |
| 0.17.0 | 1 | OFF | 24.4 | 41.000 | 41.084 | 41.155 | 17.698 | 0 / 0 | 200 |
| 0.17.0 | 1 | ON | 11,361.8 | 0.080 | 0.094 | 0.171 | 6.159 | 192 / 8 | 8 |
| 0.17.0 | 8 | OFF | 194.9 | 41.001 | 41.135 | 41.297 | 118.395 | 0 / 0 | 1,600 |
| 0.17.0 | 8 | ON | 33,748.2 | 0.186 | 0.368 | 0.582 | 51.415 | 1,536 / 64 | 64 |
| 0.17.0 | 32 | OFF | 389.8 | 41.000 | 41.215 | 41.937 | 450.655 | 0 / 0 | 6,400 |
| 0.17.0 | 32 | ON | 42,327.6 | 0.316 | 0.666 | 1.059 | 197.909 | 6,144 / 256 | 256 |

Every recorded `server_prepared_remaining` gauge was **0** after
scenario pool release/reset, and the test reports zero LRU evictions
because its eight distinct statements fit within the capacity of 16.
C3 integration separately forces eviction with capacity two.

**Important limitation:** the cache-OFF local TCP path suffered a
~41 ms response delay for repeated COM_STMT_CLOSE-heavy workloads.
This dominates the enormous observed ratio. It is not a valid
extrapolation of general app throughput or of cache gains on TLS,
Unix sockets or low-latency kernels. Run repeated identical tests
on isolated dedicated hardware, investigate TCP_NODELAY/Nagle,
and compare CPU, memory, server prepare counts and p99 under real
application transaction boundaries before making performance claims.
