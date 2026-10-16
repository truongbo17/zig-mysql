# Sprint E3 — IPv6 and Windows portability evidence

## Verified scope

- Linux GitHub Actions connects from Zig `std.Io.net.IpAddress.parseLiteral("[::1]:33311")` to a **real AF_INET6 loopback listener**, relaying locally to disposable MySQL 8.0.46 on IPv4 Docker. It exercises connection, authentication, PING and binary prepared Vietnamese text. The container itself is **not** IPv6-native; do not claim IPv6 server bind or dual-stack Docker.
- On Linux and macOS, TLS uses OpenSSL 3 and nonblocking POSIX `fcntl`. Windows TLS is **not supported**: the backend currently has an explicit `UnsupportedTlsPlatform` return for non-Linux/macOS, uses POSIX descriptors and requires native OpenSSL link configuration.
- The Windows probe workflow `.github/workflows/e3-windows-probe.yml` attempts native `zig build test` on windows-latest for Zig 0.16 and 0.17, marking the result informational to document blockers rather than making unsupported platform claims.
- Verified TLS certificate rejection tests remain on Linux MySQL 8.4 in `integration/tls_local.zig`; this is **not** a Windows TLS test. MacOS Windows portability is not inferred from Linux CI.

## Compatibility contract

| Platform | IPv4 TCP | IPv6 TCP | Verified OpenSSL TLS | Unix sockets |
|---|---|---|---|---|
| Linux GitHub CI | Tested | Test on ::1 relay | Existing TLS integration, high-CCU #65 blocked | Tested |
| macOS | Supported by current POSIX code path, without E3 live runner evidence | Not yet live tested in E3 | Existing backend, macOS runner not tested in E3 | Not tested in E3 |
| Windows | Not certified | Not certified | Unsupported (POSIX fcntl backend) | Unsupported |

No Windows support or production readiness claims until native Windows build+TLS semantics, lifetime safety and CI are independently demonstrated. Sprint D #65 and OPS release epic #13 remain blockers after Sprint E.


## Native Windows probe result — 2026-10-16

GitHub Actions run https://github.com/truongbo17/zig-mysql/actions/runs/38830594320 tested Zig 0.16/0.17 on native Windows runners. Both `zig build test` probe steps FAILED: no native dynamic `ssl` and `crypto` libraries found. The workflow's overall success is informational because these unsupported-platform probe steps use continue-on-error. This is NOT a Windows build pass or a Windows compatibility claim.