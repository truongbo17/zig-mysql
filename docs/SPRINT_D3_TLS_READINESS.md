# D3 — OpenSSL TLS readiness experiment

Issue #30. Zig 0.16/0.17 `std.Io` does not currently expose a
portable readiness registration API for foreign OpenSSL sockets.
This change substitutes a libc `poll` readiness wait for each
`SSL_ERROR_WANT_READ/WRITE` instead of fixed 1 ms sleep retries.

- Socket remains nonblocking and OpenSSL retains hostname/CA verification.
- POLLIN/POLLOUT is selected based on **the actual OpenSSL error**, even
  when SSL_read requests write readiness or SSL_write requests read readiness.
- POSIX Linux/macOS only, same platform limit as the existing TLS backend.
- A 10 ms maximum poll interval introduces a cooperative cancellation
  check, avoiding an indefinite blocking syscall on the Threaded backend.
- Negative poll/invalid fd signals a TLS socket error; the client must
  discard the connection.
- This is NOT an event-loop-native `std.Io` registration and it consumes a
  native worker thread while polling. No CPU improvement claim until
  reproducible benchmark with the same TLS workload demonstrates it.

## Acceptance

- [ ] Zig 0.16 + 0.17 exact-head CI, live TLS handshake and SQL suite
- [ ] Peer stall / server close / cancellation matrix under TLS
- [ ] CPU and latency measurement against preceding 1 ms sleep baseline
- [ ] macOS validation, independent review, rollback decision

Production release gate #13 remains open. Keep #30 open until the full
acceptance criteria are demonstrated.
