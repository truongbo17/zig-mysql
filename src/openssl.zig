const std = @import("std");

// TLS backend uses OpenSSL's public C ABI and cancellable nonblocking sockets.
// A 1ms Io sleep on SSL_ERROR_WANT_READ/WRITE prevents busy-spin and makes
// the handshake/read/write safely interruptible by std.Io.Select. This is
// currently a portability/latency tradeoff rather than event-loop-native poll.
// The MySQL server commonly sends an
// optional CertificateRequest, which Zig 0.16/0.17's std.crypto.tls.Client
// currently does not handle. No MySQL C client library is used.
// https://docs.openssl.org/3.0/man3/SSL_set1_host/
// https://docs.openssl.org/3.2/man3/SSL_CTX_load_verify_locations/
const SSL_METHOD = opaque {};
const SSL_CTX = opaque {};
const SSL = opaque {};
const X509 = opaque {};

extern "ssl" fn TLS_client_method() ?*const SSL_METHOD;
extern "ssl" fn SSL_CTX_new(?*const SSL_METHOD) ?*SSL_CTX;
extern "ssl" fn SSL_CTX_free(*SSL_CTX) void;
extern "ssl" fn SSL_CTX_set_verify(*SSL_CTX, c_int, ?*const anyopaque) void;
extern "ssl" fn SSL_CTX_load_verify_locations(*SSL_CTX, ?[*:0]const u8, ?[*:0]const u8) c_int;
extern "ssl" fn SSL_CTX_set_default_verify_paths(*SSL_CTX) c_int;
extern "ssl" fn SSL_new(*SSL_CTX) ?*SSL;
extern "ssl" fn SSL_free(*SSL) void;
extern "ssl" fn SSL_set_fd(*SSL, c_int) c_int;
extern "ssl" fn SSL_set1_host(*SSL, [*:0]const u8) c_int;
extern "ssl" fn SSL_ctrl(*SSL, c_int, c_long, ?*anyopaque) c_long;
extern "ssl" fn SSL_connect(*SSL) c_int;
extern "ssl" fn SSL_get_error(*SSL, c_int) c_int;
extern "c" fn fcntl(c_int, c_int, ...) c_int;
extern "ssl" fn SSL_get_verify_result(*SSL) c_long;
extern "ssl" fn SSL_get1_peer_certificate(*SSL) ?*X509;
extern "crypto" fn X509_free(*X509) void;
extern "ssl" fn SSL_read(*SSL, [*]u8, c_int) c_int;
extern "ssl" fn SSL_write(*SSL, [*]const u8, c_int) c_int;
extern "ssl" fn SSL_shutdown(*SSL) c_int;

pub const Session = struct {
    ctx: *SSL_CTX,
    ssl: *SSL,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, fd: c_int, host: []const u8, ca_file: ?[]const u8) !Session {
        if (host.len == 0 or std.mem.indexOfScalar(u8, host, 0) != null) return error.InvalidTlsHost;
        const host_z = try allocator.dupeSentinel(u8, host, 0);
        defer allocator.free(host_z);
        const ctx = SSL_CTX_new(TLS_client_method()) orelse return error.TlsContextFailed;
        errdefer SSL_CTX_free(ctx);
        SSL_CTX_set_verify(ctx, 1, null); // SSL_VERIFY_PEER
        if (ca_file) |path| {
            const path_z = try allocator.dupeSentinel(u8, path, 0);
            defer allocator.free(path_z);
            if (SSL_CTX_load_verify_locations(ctx, path_z, null) != 1) return error.TlsCaLoadFailed;
        } else if (SSL_CTX_set_default_verify_paths(ctx) != 1) {
            return error.TlsCaLoadFailed;
        }
        const ssl = SSL_new(ctx) orelse return error.TlsSessionFailed;
        errdefer SSL_free(ssl);
        // The socket MUST be nonblocking: SSL_read/SSL_write/SSL_connect
        // can then be cancelled safely by the Zig Io runtime on WANT_READ /
        // WANT_WRITE, rather than holding an uninterruptible OpenSSL thread.
        // F_GETFL=3, F_SETFL=4 on Linux and macOS.
        const nonblock: c_int = switch (@import("builtin").target.os.tag) {
            .linux => 0x800,
            .macos => 0x0004,
            else => return error.UnsupportedTlsPlatform,
        };
        const existing_flags = fcntl(fd, 3);
        if (existing_flags < 0 or fcntl(fd, 4, existing_flags | nonblock) < 0)
            return error.TlsSocketFailed;
        if (SSL_set_fd(ssl, fd) != 1) return error.TlsSocketFailed;
        if (SSL_set1_host(ssl, host_z) != 1) return error.TlsHostFailed;
        // SSL_CTRL_SET_TLSEXT_HOSTNAME = 55, TLSEXT_NAMETYPE_host_name = 0.
        if (SSL_ctrl(ssl, 55, 0, @ptrCast(host_z.ptr)) != 1) return error.TlsHostFailed;
        while (true) {
            const n = SSL_connect(ssl);
            if (n == 1) break;
            switch (SSL_get_error(ssl, n)) {
                2, 3 => try std.Io.sleep(io, .fromMilliseconds(1), .awake), // WANT_READ/WRITE
                else => return error.TlsHandshakeFailed,
            }
        }
        const certificate = SSL_get1_peer_certificate(ssl) orelse return error.TlsCertificateMissing;
        X509_free(certificate);
        if (SSL_get_verify_result(ssl) != 0) return error.TlsCertificateInvalid;
        return .{ .ctx = ctx, .ssl = ssl };
    }

    pub fn deinit(self: *Session) void {
        _ = SSL_shutdown(self.ssl);
        SSL_free(self.ssl);
        SSL_CTX_free(self.ctx);
    }

    pub fn readExact(self: *Session, io: std.Io, destination: []u8) !void {
        var used: usize = 0;
        while (used < destination.len) {
            const count: c_int = @intCast(@min(destination.len - used, std.math.maxInt(c_int)));
            const n = SSL_read(self.ssl, destination[used..].ptr, count);
            if (n <= 0) {
                switch (SSL_get_error(self.ssl, n)) {
                    2, 3 => {
                        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
                        continue;
                    },
                    6 => return error.EndOfStream, // SSL_ERROR_ZERO_RETURN
                    else => return error.TlsReadFailed,
                }
            }
            used += @intCast(n);
        }
    }

    pub fn writeAll(self: *Session, io: std.Io, bytes: []const u8) !void {
        var used: usize = 0;
        while (used < bytes.len) {
            const count: c_int = @intCast(@min(bytes.len - used, std.math.maxInt(c_int)));
            const n = SSL_write(self.ssl, bytes[used..].ptr, count);
            if (n <= 0) {
                switch (SSL_get_error(self.ssl, n)) {
                    2, 3 => {
                        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
                        continue;
                    },
                    else => return error.TlsWriteFailed,
                }
            }
            used += @intCast(n);
        }
    }
};
