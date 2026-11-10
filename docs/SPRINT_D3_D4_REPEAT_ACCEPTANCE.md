# Sprint D3 / D4 — Mainline regression acceptance

**Scope:** verify current mainline D3 POSIX 10ms readiness polling ([PR #62](https://github.com/truongbo17/zig-mysql/pull/62)) and D4 Group terminal-operation fix ([PR #127](https://github.com/truongbo17/zig-mysql/pull/127)) together, without resurrecting any of the archived native teardown diagnostic PRs.

[CI workflow](../.github/workflows/d3-d4-repeat-acceptance.yml) runs 20 completely independent ReleaseFast 1/8/32/64/128-borrower stress process matrices with pool=32 per Zig 0.16 and 0.17; all original pool checkout, query deadlines and verified CA+hostname TLS remain enabled. It monitors the fatal double-free/SIGSEGV markers and fails on ANY abnormal process exit. The workflow is intentionally separate from the default one-pass integration suite to detect the intermittent #65 failure.

The same CI additionally checks macOS 15 on both Zig versions with native Homebrew OpenSSL 3, core Zig tests, and deterministic silent greeting / stalled TLS ServerHello cancellation via `integration/stall_server.py`. It is **not** a live macOS database/TLS throughput benchmark, and does not establish macOS production support by itself.

**Do not close [#65](https://github.com/truongbo17/zig-mysql/issues/65) from a single or even one successful 20-run sample.** In 2026-10 native GDB backtraces showed main thread in OpenSSL 3 `OPENSSL_cleanup` while detached Zig I/O worker pthread TLS destructors were inside `CRYPTO_THREAD_write_lock`; see [CI #39395143331](https://github.com/truongbo17/zig-mysql/actions/runs/39395143331). Candidate [PR #126](https://github.com/truongbo17/zig-mysql/pull/126), invoking `OPENSSL_thread_stop` after each operation, was closed unmerged as unsafe for reusable worker threads. Its 30x green benchmarks do not justify adopting its API side effects.

This additional test is feature-acceptance evidence only. D3 #30 still needs silent peer/handshake cancellation and macOS review. D4 #31 requires repeated p99, CPU, RSS, FD and error budgets. Production #13 requires a frozen source SHA, two actual 24-hour staging runs, HA/security and approval. Never label this workflow a 24h soak.
