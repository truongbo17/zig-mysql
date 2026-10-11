# Sprint C — Transactions and prepared statement cache

Engineering evidence tracker. **Feature CI is not production certification.**
The independent [OPS #13](https://github.com/truongbo17/zig-mysql/issues/13)
remains open until real 24-hour soak, HA, security and release approval.

## Scope and evidence

| Feature | Issue | Evidence |
| --- | --- | --- |
| C1 — Nested savepoints and strict identifier validation | [#24](https://github.com/truongbo17/zig-mysql/issues/24) | [PR #56](https://github.com/truongbo17/zig-mysql/pull/56), [Zig 0.16/0.17 CI](https://github.com/truongbo17/zig-mysql/actions/runs/38141738935) |
| C2 — Bounded COMMIT/ROLLBACK and unknown outcomes | [#25](https://github.com/truongbo17/zig-mysql/issues/25) | [PR #57](https://github.com/truongbo17/zig-mysql/pull/57) — final exact-head CI required |
| C3 — Opt-in per-connection LRU with reset/schema invalidation | [#26](https://github.com/truongbo17/zig-mysql/issues/26) | [PR #58](https://github.com/truongbo17/zig-mysql/pull/58), [initial Zig CI](https://github.com/truongbo17/zig-mysql/actions/runs/38141994622) — final post-base CI required |
| C4 — Cache off/on and regression benchmarking | [#27](https://github.com/truongbo17/zig-mysql/issues/27) | Implementation and exact-head CI pending |

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
