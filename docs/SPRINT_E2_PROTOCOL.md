# Sprint E2 — Protocol fuzz and prepared large packets

- Fixed-seed 4096-case corpus targets length-coded integers/strings, malformed cursor offsets, truncated handshakes, and packet header parsing with no network.
- Boundary matrix checks classic 24-bit packet fragmentation, including exact multiples that require a final zero-length continuation packet.
- Live tests perform one >16 MiB prepared binary BLOB parameter and result roundtrip through MySQL 8.0 TCP, MySQL 8.4 verified TLS and Unix socket, MySQL 9.x Unix, MariaDB 10.11/11.4. Values include invalid UTF-8, NUL and 0xFE; byte-exact comparison and subsequent COM_PING verify framing synchronization.
- MariaDB disposable fixture opts into 64 MiB max_allowed_packet. The driver still bounds individual inbound message allocations via Config.max_message_size. This integration test is not evidence of a 24h load soak or production security sign-off.
- Exact-head CI is required for both Zig 0.16 and 0.17 before #33 is closed.
