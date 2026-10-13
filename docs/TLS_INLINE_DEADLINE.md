# TLS inline deadline experiment (#65, D3)

A verified MySQL TLS connection uses a nonblocking socket. Unlike the
plaintext path, TLS `readExact` and `writeAll` already loop cooperatively
around OpenSSL WANT_READ/WANT_WRITE states. For bounded commands we can
record the command start time on the connection's TLS session, check
elapsed monotonic time on every I/O loop iteration, and return
`error.QueryTimeout` as soon as it expires.

This avoids creating a second `std.Io.Select` worker/timer for *each*
bounded TLS query. The existing `withTimeout` wrapper still poisons
the connection after a timeout or cancellation; bounded COMMIT and
ROLLBACK continue translating a transport timeout into ambiguous
transaction outcomes. The connection is not retried.

- This is a command I/O deadline; it cannot preempt CPU-bound parsing or
  blocking user callbacks that do not enter nonblocking TLS I/O.
- Streaming per-row `nextWithTimeout` still has an independent
  `std.Io.Select` implementation and needs separate CCU coverage.
- TLS connect/handshake timeout remains an independent bounded connect
  wrapper; this change does not alter certificate validation.
- Plaintext connections retain their existing timeout behavior.
- Session deadlines are cleared after each operation and are never
  shared between pool borrowers.

Required evidence before merge:
1. Zig 0.16/0.17 exact-head unit and live verified-TLS integration.
2. Real server sleep deadline and broken-connection/rollback tests.
3. Strict 128-CCU verified-TLS benchmark with fatal allocator logging,
   plus repeat runs (no heap corruption or segfault).
4. Compare CPU and p99 against baseline; if safety or performance
   regresses, keep as draft and do not merge.

Production gate #13 and blocker #65 remain open until verification.
