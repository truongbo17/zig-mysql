# D1 follow-up: streaming command lifecycle telemetry

Complements PR #60 / issue #28. The opt-in metrics recorder now captures
**complete text and binary stream lifetimes**, including row consumption and
a graceful `deinit(io)` drain. For `callResults`, completion of the terminal
result part or a graceful drain records the command. One command produces one
observation: it is **not** recorded again when `deinit` follows a completed
`next` sequence. Errors before metadata is returned are also classified.

## Scope / contract

- A streaming command's observation starts before COM_QUERY or
  COM_STMT_EXECUTE and ends at EOF or safe drain.
- For a premature stream error, the first error terminates the observation.
  If an error poisons the socket, subsequent deinit does not count twice.
- `queryRowsWithTimeout` and `executeRowsWithTimeout` retain their existing
  timed-startup semantics from PR #60; the timeout wrapper observes initial
  metadata, so an inner stream does not record a second event.
- `abandon()` has no `std.Io` parameter and cannot calculate elapsed time.
  Explicit abandoned streaming sessions are **not observed** by this patch.
  A separate API evolution is required to track abandonment precisely.
- No SQL, bound values, user identifiers or error messages are used as labels.
- All metrics remain disabled by default and never change wire protocol bytes.

## Acceptance

- [ ] Exact-head unit and real MySQL/MariaDB CI on Zig 0.16 and 0.17
- [ ] No duplicate observations on stream EOF + deinit
- [ ] Mid-stream failure and deadline classification on real MySQL/TLS
- [ ] No use-after-free from pooled borrower recorder
- [ ] Disabled-path and streaming-overhead benchmark

This is an incremental PR and cannot close issue #28 alone or production
release gate #13.
