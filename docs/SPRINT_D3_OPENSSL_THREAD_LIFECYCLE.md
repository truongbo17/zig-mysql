# D3 P0 — OpenSSL thread-local cleanup candidate

**Status: DRAFT, NOT ACCEPTED, not production-certified.**

## Reproduced native mechanism

[Exact Zig 0.16 GDB CI #39395143331](https://github.com/truongbo17/zig-mysql/actions/runs/39395143331):
at repeat 7, main thread was in `OPENSSL_cleanup` called from
`__run_exit_handlers`, while many Zig `std.Io.Threaded` workers were
still in pthread thread-local destructors (`__nptl_deallocate_tsd` →
`CRYPTO_THREAD_write_lock` in `libcrypto.so.3`). A separate explicit
`OPENSSL_cleanup()` diagnostic faulted between begin/end markers.
`std.Io.Threaded` uses detached workers and wait-group completion that
can precede pthread TLS destructor completion. Native process-exit
cleanup therefore races worker cleanup.

## Candidate and evidence

[PR #126](https://github.com/truongbo17/zig-mysql/pull/126) adds
`OPENSSL_thread_stop()` after the driver returns from a synchronous TLS
init, read, write or teardown on that worker. **This does not disable CA /
hostname verification, connection / pool / query timeouts, or OpenSSL
session/CTX freeing.** The candidate never calls process-global
`OPENSSL_cleanup()`. Its objective is to release per-thread OpenSSL data
*before* Zig's detached worker signals task completion.

An initial exact-head [CI #39395885311](https://github.com/truongbo17/zig-mysql/actions/runs/39395885311)
completed 30 distinct optimized verified-TLS pool32 / 128-borrower
processes on **each** Zig 0.16 and Zig 0.17, without the prior SIGSEGV.
This is root-cause-directed regression evidence, not a proof of all
workloads or platforms.

## Critical integration caveat

`OPENSSL_thread_stop()` affects the **default OpenSSL per-thread
library context shared by other components**, not just this client.
The driver should not silently break a host application's independent
OpenSSL operations. This is an **experimental API boundary** until
cross-library coexistence (e.g. external EVP digest spanning SQL
calls), TLS failures and cancellation, pool reset, release-optimized
stress on both Zig versions, plus macOS integration are independently
reviewed and pass. A host application using long-lived OpenSSL
thread-local state across nested driver calls may require an isolated
OpenSSL library context or integration-specific lifecycle ownership.

The OpenSSL library documentation also discourages reusable libraries
from invoking process-global `OPENSSL_cleanup()` because other
components may still use OpenSSL. See
https://docs.openssl.org/3.0/man3/OPENSSL_init_crypto/ .

**Do not merge or close #65/#30/#31 based on green stress alone.**
Production #13 additionally requires real 24-hour isolated staging
soak for both Zig versions, HA/security evidence, protected release
controls and human sign-off.
