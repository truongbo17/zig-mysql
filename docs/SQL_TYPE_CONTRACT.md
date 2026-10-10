# SQL Type/Decoder Audit & Additive API Contract (A0, #14)

This document records the current behavior of **zig-mysql** at the reviewed
source revision. It is a contract for additive feature issues #15–#19, not a
claim that unimplemented typed conversions already work.

## Data path

1. `Client.query` uses text-protocol `COM_QUERY`, reads length-encoded
   `NULL` or raw byte values in `Client.readResult(io, false)`.
2. `Client.execute` builds `COM_STMT_EXECUTE` from `Param` union
   (`null`, `int`, `uint`, `float`, `text`, `bytes`, `boolean`),
   then decodes binary rows with `parseBinaryValue`.
3. Both result paths expose `Row.values: []const ?[]const u8`.
   There is **no Zig-level typed scanner** today. Non-null `bytes` have no
   implicit UTF-8 or JSON guarantee.
4. `Column` exposes `name`, MySQL `type_code` and `flags`. The
   parser **currently discards charset ID and declared maximum column
   length**, and also does not expose schema/table/decimals.
5. `RowStream` is text-protocol only; it has per-row `row_arena` and
   metadata arena. The bytes returned by `next()` expire on next call or
   `deinit()`; `Result` owns all buffered values until `Result.deinit()`.
6. Pool sessions reset on release. A `Statement` handle belongs to its
   connection/session and must not be used after session reset or pool
   checkout by another borrower.

## Concrete existing type mapping

| MySQL type | Text SELECT | Prepared binary result | Current risk / action |
| --- | --- | --- | --- |
| TINY/SHORT/LONG/LONGLONG/INT24/YEAR | Raw decimal ASCII | Integer reconstructed into decimal ASCII using unsigned flag | Typed scanner must check overflow and signedness instead of implicit coercion |
| FLOAT/DOUBLE | Raw server decimal ASCII | `f32`/`f64` decoded then formatted into decimal ASCII | Formatting is **not lossless binary bit-pattern representation**; never use float for money |
| DECIMAL/NEWDECIMAL (0/246) | Raw decimal ASCII | Length-encoded bytes copied verbatim | No decimal validation today; issue #15 adds opt-in precision-safe handling |
| DATE/DATETIME/TIMESTAMP/NEWDATE | Raw text | MySQL temporal bytes formatted back as text | Zero temporal values, microseconds, ambiguous timezone and malformed components need explicit validation (#16) |
| TIME | Raw text | Sign, day count and time converted to textual hours | Negative/extended TIME and maximum `838:59:59` need typed tests (#16) |
| JSON (245), BLOB/BINARY (249–252), TEXT/VARCHAR/VAR_STRING (15/253/254) | Raw bytes | Length-encoded bytes copied | No blanket UTF-8, JSON validation or arbitrary NUL truncation; tests and typed helpers in #17 |
| BIT/ENUM/SET/GEOMETRY | Raw bytes | Length-encoded bytes copied | Expose exact bytes; do not claim semantic conversion |
| Unknown binary type | Raw bytes if server sends it | `error.UnsupportedColumnType` and socket marked broken during result parse | Fail-closed behavior must remain; fuzz/parser coverage (#33) |

Relevant code: `src/client.zig` (`Param`, `parseColumn`,
`parseBinaryValue`, `readResult`, `RowStream`),
`src/protocol.zig` (`Cursor`), `src/root.zig`,
`integration/live.zig` and `integration/mariadb.zig`.

## Opt-in API and compatibility decisions

- **Do not break** `Row`, `Param`, `Result` or existing `Column` field
  access. New `Param` alternatives, value/decoder modules or new
  `Column` metadata may be added with explicit tests and docs.
- `DECIMAL` is a **decimal ASCII lexical value**, never a floating point
  intermediate. Strict value validation must fail on malformed syntax and
  overflow, and its scale/precision rules must be documented (#15).
  MySQL's own SQL mode and destination precision may still round/cast.
- Temporal types must distinguish DATE vs DATETIME/TIMESTAMP and signed
  duration TIME. Avoid implicit timezone conversion: MySQL TIMESTAMP is
  affected by server session timezone. Zero dates require an explicit
  opt-in or explicit error; distinguish zero-date from a valid Gregorian
  value (#16).
- `BLOB`/`BINARY` is opaque bytes and may contain `0x00` and invalid
  UTF-8. `TEXT` is not unconditionally valid UTF-8; JSON validation should
  be opt-in with bounded allocation and no hidden normalization (#17).
- A typed scanner must express `NULL` as nullable, not silently
  coerce it into zero/empty text. Integer overflow/type mismatch must fail;
  no implicit lifetime extension of a streaming row (#18–#19).
- Text result bytes are row-owned and buffered binary-decoded bytes are
  result-owned; a copied/owned typed value must say which allocator owns it.
- Invalid parser lengths/binary framing or canceled reads poison the
  connection; SQL-level server errors do not automatically imply a
  broken wire. No retry of ambiguous writes.

## Exact acceptance matrix for Sprint A

- Unit: decimal lexical limits/scale, invalid forms, zero/negative; leap
  dates/invalid calendar/microseconds; NULL/empty distinctions, invalid
  UTF-8 as raw bytes, embedded NUL; unsigned overflow and truncated
  binary packets.
- Integration: MySQL 8.0/8.4 and MariaDB 10.11/11.4 using both text and
  `COM_STMT_EXECUTE`; verify actual returned bytes and MySQL type codes,
  including high-precision DECIMAL, time fractional precision and JSON/BLOB.
- CI: Zig 0.16 and 0.17 on exact PR head; no previously passing tests
  disabled; update README and backlog ticket state in each feature PR.
- **No planned feature gets marked DONE until its own exact-head green CI
  and merged PR provide the evidence.**

## Known blockers outside Sprint A

- Server's SQL mode, timezone and charset semantics are not overridden
  by the driver; callers must configure known session settings.
- Prepared result streaming, multi-resultsets and statement caching are
  not yet implemented (#20–#23, #26).
- This audit does not certify general production readiness; the independent
  24h/HA/security epic #13 remains open.
