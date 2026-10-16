# Sprint E — Compatibility work and Sprint D deferral

Status as of 2026-10-16. Sprint E is permitted to proceed independently of Sprint D.
No compatibility work waives TLS reliability or the production release gate.

| Workstream | Issue | Acceptance |
|---|---|---|
| E1: Charset/collation/SQL mode | #32 | Explicit utf8mb4 collation selection, Vietnamese/UTF-8 prepared byte roundtrip, ANSI_QUOTES, NO_BACKSLASH_ESCAPES, session timezone across real MySQL/MariaDB; exact-head Zig 0.16 and 0.17 |
| E2: Protocol malformed/fuzz and >16 MiB prepared | #33 | Deterministic parser corpus, strict bounded allocations and wire framing, real prepared huge BLOB tests; exact-head both Zig versions |
| E3: IPv6 and Windows portability | #34 | Live IPv6 loopback or explicit unsupported reason; honest Windows build/run matrix, no unsupported Windows TLS claims |

## Deferred Sprint D — remains OPEN

- D1 #28 metrics: completed.
- D2 #29 batch: completed.
- D3 #30 native TLS readiness: blocked by #65.
- D4 #31 verified TLS high-CCU: blocked by #65.
- P0 #65: intermittent native TLS heap double free / SIGSEGV under 32 TLS connections and 128 borrowers, proven across Zig 0.16 and 0.17. A transient passing benchmark does not clear it.
- OPS #13: 24-hour soak plus HA/security/provenance acceptance remains an independent release blocker.

**Release decision: Not production-certified.** A finished Sprint E is a feature milestone, not permission to ship into untrusted production workloads. Follow up D3/D4/#65 and OPS #13 before approval.
