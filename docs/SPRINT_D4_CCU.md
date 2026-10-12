# Sprint D4 — High-CCU and verified TLS profiling

For issue #31. The reproducible workload executes `SELECT 1` through a
bounded pool of **32** connections, with client counts **1, 8, 32, 64 and
128** and 32 requests per worker. Pool checkout, command execution and
session reset are included in latency.

Run against disposable MySQL fixtures:

```sh
zig build -Doptimize=ReleaseFast high-ccu-bench
zig build -Doptimize=ReleaseFast high-ccu-tls-bench
```

The plain fixture is MySQL 8.0 on 127.0.0.1:33306, zigtest credentials
as in `integration/run.sh`. The TLS fixture is MySQL 8.4 at :33307,
with the generated server certificate CA at
`/tmp/zig-mysql-test-ca.pem`, verifying its certificate hostname.

Both benchmarks emit requests/s, p50/p95/p99 in milliseconds, process CPU
time (Linux clock), connection creation/closure, pool waits and checkout
timeouts. On Linux `integration/run.sh` also wraps the binary with
`bench/profile_runner.py` to observe **actual live** peak RSS and open
file descriptor counts from `/proc`; absence of observed samples fails
this diagnostic step rather than inventing values.

These are short CI diagnostics and cannot establish a production service
level objective. A valid acceptance report must also include realistic
application SQL and payload sizes, errors/failures, packet faults, 24-hour
soak and independent HA/security approval (OPS #13).

- [ ] Exact-head Zig 0.16 and 0.17 MySQL/TLS benchmark CI PASS
- [ ] Record measured output with commit SHA
- [ ] Compare TLS and non-TLS p99/CPU and RSS/fd data under same workload
- [ ] Repeat on isolated representative staging hardware

Do not close issue #31 or production epic #13 without the evidence above.
