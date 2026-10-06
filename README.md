# zig-mysql

A native Zig client for the MySQL classic client/server protocol. The project is under active development; the API and compatibility claims below reflect tests that have actually run.

## About

`zig-mysql` aims to offer a small, explicit API for connecting to MySQL, executing parameterized statements, and reading results without a MySQL C client library. The protocol implementation is native Zig; verified TLS uses OpenSSL 3 because Zig 0.16/0.17's TLS client cannot process the optional client-certificate request in MySQL's default TLS handshake. This is a new implementation, informed by the [MySQL protocol documentation](https://dev.mysql.com/doc/dev/mysql-server/latest/PAGE_PROTOCOL.html), the API and test practices of [Go's MySQL driver](https://github.com/go-sql-driver/mysql), and lessons from [MyZQL](https://github.com/speed2exe/myzql). Code is not copied from either driver.

## Version Compatibility

| Component | Version | Status |
| --- | --- | --- |
| Zig | 0.17.0 | Unit and integration tests pass |
| Zig | 0.16.0 | Unit and integration tests pass |
| MySQL | 8.0.46 | TCP, native authentication, ping, text queries, results tested |
| MySQL | 8.4.11 | Unix socket and verified TLS, full caching SHA2 authentication, ping, prepared SELECT tested |
| MySQL | 9.7.1 | Unix socket, full caching SHA2 authentication, ping, prepared SELECT tested |
| MariaDB | 10.11 / 11.x | Planned integration test |

Compatibility is established by a real server test, rather than inferred from a version string. Server capabilities are negotiated during the handshake.

## Features

| Feature | Status |
| --- | --- |
| TCP, Unix socket and classic protocol handshake | Implemented |
| `mysql_native_password` | Implemented |
| `caching_sha2_password` fast and Unix socket full authentication | Implemented |
| Ping | Implemented |
| Text `COM_QUERY` including result rows and NULL | Implemented |
| Server error code and SQLSTATE | Implemented |
| Multi-packet messages | Implemented |
| Prepared statements, typed parameter binding, binary result rows | Implemented |
| Transactions (`begin`, `commit`, `rollback`) | Implemented |
| Verified TLS with CA and hostname checks, full SHA2 authentication over TLS | Implemented (OpenSSL 3) |
| Streaming rows, timeouts, pooling | Planned |

Unencrypted TCP does **not** send a cleartext password for full SHA2 authentication. Such a server request returns `error.SecureTransportRequired`. `LOCAL INFILE` is disabled. TLS operations currently use blocking OpenSSL I/O.

## Requirements

- Zig 0.16.0 or 0.17.0.
- OpenSSL 3 development/runtime libraries for the TLS backend. On macOS, the default prefix is `/opt/homebrew/opt/openssl@3`; override with `-Dopenssl_prefix=/your/prefix`.

## Build and test

```sh
zig build test
zig build integration  # requires the integration MySQL container on 127.0.0.1:33306
bash integration/run.sh  # disposable MySQL 8.0, 8.4 and 9.7 Docker matrix
zig build tls-integration  # requires local MySQL 8.4 on port 33307 and its CA at /tmp/zig-mysql-test-ca.pem
```

`zig build integration` expects a `zigtest` database and a `zigtest` user with password `zig_mysql_test` using `mysql_native_password`. `integration/run.sh` creates these test containers and cleans them up. These credentials are for disposable test servers only.

## Add as a Zig dependency

```sh
zig fetch --save git+https://github.com/truongbo17/zig-mysql#main
```

In `build.zig`, import `b.dependency("zig_mysql", .{}).module("zig_mysql")` into your application module. OpenSSL is linked by the package build module.

## Example

```zig
var threaded: std.Io.Threaded = .init(allocator, .{});
defer threaded.deinit();
const io = threaded.io();
var client = try mysql.Client.connect(allocator, io, .{
    .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:3306") },
    .username = "app",
    .password = password,
    .database = "app_db",
    .tls = .{ .host = "db.example.com", .ca_file = "/path/to/ca.pem" },
});
defer client.deinit(io);

var result = try client.query(io, "SELECT id, name FROM users");
defer result.deinit();
for (result.value.rows.items) |row| {
    // Values from the text protocol are nullable byte slices.
    _ = row;
}
```

Do not concatenate untrusted input into SQL. Use `prepare` and `execute` with typed parameters for input values.

## Protocol references

- [Packet framing](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_packets.html)
- [Connection phase](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase.html)
- [Text resultsets](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_com_query_response_text_resultset.html)
- [Prepared statements](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_command_phase_ps.html)
- [Authentication](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_connection_phase_authentication_methods.html)
- [MySQL TLS exchange](https://dev.mysql.com/doc/dev/mysql-server/latest/page_protocol_basic_tls.html)
- [OpenSSL hostname verification](https://docs.openssl.org/3.0/man3/SSL_set1_host/)

## License

MIT. See [LICENSE](LICENSE).
