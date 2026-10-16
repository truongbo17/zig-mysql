# Sprint E — Compatibility acceptance report

**Completed: 2026-10-16. Status: 3 of 3 issues closed and merged to main.**
Sprint E was delivered independently after explicit deferral of the Sprint D3/D4
native TLS concurrency defect. **Sprint E completion does not grant a production release.**

| Item | Outcome | Merge commit | Exact-head acceptance evidence |
| --- | --- | --- | --- |
| E1 [#32](https://github.com/truongbo17/zig-mysql/issues/32) — Charset/collation/SQL modes | DONE, [PR #120](https://github.com/truongbo17/zig-mysql/pull/120) | `81675bd2a1875905f7dd5f8c8ce87f1923e58815` | [E-only CI #38831694065](https://github.com/truongbo17/zig-mysql/actions/runs/38831694065): PASS Zig 0.16 and 0.17 |
| E2 [#33](https://github.com/truongbo17/zig-mysql/issues/33) — Parser fuzz / >16 MiB prepared | DONE, [PR #121](https://github.com/truongbo17/zig-mysql/pull/121) | `3e41f9a03276e02e4518dba6b9a485d908553df0` | [Full CI #38830961959](https://github.com/truongbo17/zig-mysql/actions/runs/38830961959): PASS Zig 0.16 and 0.17 |
| E3 [#34](https://github.com/truongbo17/zig-mysql/issues/34) — IPv6 / Windows evaluation | DONE as **evaluation**, [PR #122](https://github.com/truongbo17/zig-mysql/pull/122) | `48ad1a5014d37e6e9426271fd1ff65fa234b9278` | [E-only CI #38832510637](https://github.com/truongbo17/zig-mysql/actions/runs/38832510637): PASS Zig 0.16 and 0.17 |

## Verified features and limits

- **E1:** Typed opt-in UTF8MB4 collation in HandshakeResponse41 and fail-closed
  `@@collation_connection` check for nondefault selections; explicit Unicode
  Vietnamese prepared parameters under ANSI_QUOTES / NO_BACKSLASH_ESCAPES and
  controlled session timezone on live MySQL 8/9 and MariaDB 10/11.
- **E2:** Reproducible 4,096-case parser corpus, malformed length/cursor and
  fragmented 24-bit classic packet boundaries; prepared binary BLOB binding
  and result >16 MiB, including NUL and invalid UTF-8, with byte-for-byte
  comparison and subsequent ping to confirm packet framing synchronization.
  This is reproducible robustness coverage, not a security certification.
- **E3:** Actual AF_INET6 `[::1]:33311` TCP client connection to a
  loopback-only relay into disposable MySQL 8.0.46; tested authentication,
  ping and prepared Vietnamese query. This **does not test an IPv6-native
  MySQL server or remote IPv6 routing**. Windows native probe
  [#38832504096](https://github.com/truongbo17/zig-mysql/actions/runs/38832504096)
  attempted `zig build test` on Windows in Zig 0.16 and 0.17;
  **both build steps failed** to link absent `ssl`/`crypto` libraries.
  The probe workflow itself showed success solely due to
  `continue-on-error`. Windows remains **unsupported/not certified**.

## Explicit CI scope and release blockers

The [Sprint E compatibility CI](../.github/workflows/sprint-e.yml)
sets `SPRINT_E_DEFER_D4_TLS_CCU=1` **only for its own job**. It
still runs unit tests and live MySQL/MariaDB/TLS functional tests.
Default `Tests` continues to run the original full D4 benchmark.
That default test still failed for Zig 0.17 in
[run #38832510658](https://github.com/truongbo17/zig-mysql/actions/runs/38832510658)
with native SIGSEGV after TLS high-concurrency load. No waiver is implied.

- Sprint D1 [#28](https://github.com/truongbo17/zig-mysql/issues/28)
  and D2 [#29](https://github.com/truongbo17/zig-mysql/issues/29): DONE.
- Sprint D3 [#30](https://github.com/truongbo17/zig-mysql/issues/30)
  and D4 [#31](https://github.com/truongbo17/zig-mysql/issues/31):
  **DEFERRED / BLOCKED** on native TLS intermittent double-free/SIGSEGV
  [#65](https://github.com/truongbo17/zig-mysql/issues/65).
  Keep full connection/acquisition/health/reset/query timeout semantics.
- Production acceptance epic [#13](https://github.com/truongbo17/zig-mysql/issues/13):
  **OPEN**. A dedicated 24-hour continuous soak on a pinned release commit,
  HA, security and provenance controls must pass before any production sign-off.

**Release decision:** Feature Sprint E complete. Zig MySQL is not
production-certified. Do not call Windows supported or waive any Sprint D / OPS gate.
