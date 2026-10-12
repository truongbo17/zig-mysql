# TLS 128-CCU teardown diagnostic (#65)

Temporary experiment; **not** a production feature.

Run the identical verified-TLS 1/8/32/64/128 client mix twice:
1. One preflighted `Pool.acquireWithTimeout` per request with normal
   `Client.query` (no per-query concurrent timer).
2. The existing `Pool.acquireWithTimeout` plus
   `Client.queryWithTimeout` workload.

Both still include pool acquire timers, resetting, transport TLS and
concurrency. Only the **per-query** `std.Io.Select` timeout differs.

CI runs the no-query-timeout control **first**, so if the standard
benchmark later dies, the control evidence remains in the logs.
`MALLOC_CHECK_=3` and live RSS/fd samples are enabled on Linux.

Interpretation:
- If both workloads crash: examine OpenSSL/Pool/Io teardown, not only query timer.
- If only the timed workload crashes reliably: inspect cancellation and
  `std.Io.Select` task ownership/late cleanup for Zig 0.16.
- Either result needs repeated processes and actual allocator/backtrace
  evidence; one clean run is **not** proof of safety.

Do not merge this diagnostic test into main as a performance improvement.
Issue #65 and production epic #13 stay open until a causal fix and
independent repeat-run verification.
