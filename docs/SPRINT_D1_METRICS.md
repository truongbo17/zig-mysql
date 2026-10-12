# Sprint D1 — Command telemetry foundation

This PR introduces a **low-cardinality, allocation-free per-connection recorder**
as an initial building block for issue #28. It now instruments opt-in buffered `query`, `execute`, and `ping`, and can
export cumulative Prometheus histograms. Other command paths and the
disabled-path overhead baseline remain outstanding. **Keep #28 open.**

## Contract

- Fixed `Command` and `Outcome` enums; no SQL text, bound parameters,
  account names, server errors, passwords, or hostname-derived metric labels.
- One outcome count and one latency histogram observation per explicit
  `record` call; duration is measured externally by a monotonic clock,
  expressed in microseconds.
- Internal buckets are **disjoint**; `formatPrometheus()` emits cumulative
  Prometheus buckets and caller-owned memory.
- Recorder is a single-borrower value, **not thread-safe**; external merging
  or publication requires synchronization.
- Saturating counters avoid wraparound during long-running processes.
- Unknown durations above 5s increment the terminal +Inf bucket.

## Acceptance status / next implementation

1. [x] Fixed vocabulary, saturating counters, histogram boundaries and exporter tests.
2. [ ] Zig 0.16 and 0.17 CI against the exact PR head (not runnable in the
   editing environment); any compile failure blocks merge.
3. [ ] Extend instrumentation beyond buffered query/execute/ping to command
   deadlines, transaction ambiguity, prepared streams and CALL. Ensure exactly
   one terminal outcome for each command without double-counting timeout wrappers.
4. [x] Add caller-owned fixed-label Prometheus exposition.
   [ ] Add concurrency-safe snapshot aggregation.
5. [ ] Test command errors, interrupted streams, ambiguous COMMIT outcomes,
   and multithreaded aggregation against MySQL and MariaDB.
6. [ ] Benchmark disabled instrumentation overhead and confirm no SQL or
   parameter bytes leak to metrics output.

This foundation is not production certification: OPS epic #13 stays open.
