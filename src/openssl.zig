const std = @import("std");

// TLS backend uses OpenSSL's public C ABI and cancellable nonblocking sockets.
// Poll socket readiness on SSL_ERROR_WANT_READ/WRITE instead of sleeping.
// Short readiness polling with Io.checkCancel retains bounded cancellation
// on std.Io.Threaded; this is POSIX polling, not native Io poll registration.
// The MySQL server commonly sends an
// optional CertificateRequest, which Zig 0.16/0.17's std.crypto.tls.Client
// currently does not handle. No MySQL C client library is used.
// https://docs.openssl.org/3.0/man3/SSL_set1_host/
// https://docs.openssl.org/3.2/man3/SSL_CTX_load_verify_locations/
const builtin = @import("builtin");
const PollFd = extern struct { fd: c_int, events: c_short, revents: c_short };
const Nfds = if (builtin.target.os.tag == .macos) c_uint else c_ulong;
extern "c" fn poll([*]PollFd, Nfds, c_int) c_int;
extern "c" fn __errno_location() *c_int;
extern "c" fn __error() *c_int;
const poll_in: c_short = 0x0001;
const poll_out: c_short = 0x0004;
const poll_error: c_short = 0x0008;
const poll_invalid: c_short = 0x0020;

// Zig 0.16/0.17 has no public socket readiness operation. Poll <=10ms
// before re-entering a cancellable Io checkpoint, never poll indefinitely.
fn waitReady(io: std.Io, fd: c_int, want: c_short) !void {
    while (true) {
        try io.checkCancel();
        var event: [1]PollFd = .{.{ .fd = fd, .events = want, .revents = 0 }};
        const n = poll(&event, 1, 10);
        if (n > 0) {
            if (event[0].revents & (poll_error | poll_invalid) != 0) return error.TlsSocketFailed;
            if (event[0].revents & want != 0) return;
            if (event[0].revents != 0) return error.TlsSocketFailed;
        } else if (n < 0) {
            const err_no = if (builtin.target.os.tag == .macos) __error().* else __errno_location().*;
            if (err_no == 4) continue; // EINTR
            return error.TlsPollFailed;
        }
    }
}

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
extern "crypto" fn ERR_clear_error() void;

pub const Session = struct {
    ctx: *SSL_CTX,
    ssl: *SSL,
    fd: c_int,
    /// Deadline scoped to one command; never shared across pool borrowers.
    deadline_started: ?@TypeOf(std.Io.Clock.awake.now(@as(std.Io, undefined))) = null,
    deadline_ns: ?i128 = null,

    pub fn setDeadline(self: *Session, io: std.Io, duration: std.Io.Duration) void {
        self.deadline_started = std.Io.Clock.awake.now(io);
        self.deadline_ns = duration.toNanoseconds();
    }

    pub fn clearDeadline(self: *Session) void {
        self.deadline_started = null;
        self.deadline_ns = null;
    }

    fn checkDeadline(self: *Session, io: std.Io) !void {
        if (self.deadline_started) |start| {
            if (start.untilNow(io, .awake).toNanoseconds() >= self.deadline_ns.?)
                return error.QueryTimeout;
        }
    }



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
            ERR_clear_error();
            const n = SSL_connect(ssl);
            if (n == 1) break;
            switch (SSL_get_error(ssl, n)) {
                2 => try waitReady(io, fd, poll_in),
                3 => try waitReady(io, fd, poll_out),
                else => return error.TlsHandshakeFailed,
            }
        }
        const certificate = SSL_get1_peer_certificate(ssl) orelse return error.TlsCertificateMissing;
        X509_free(certificate);
        if (SSL_get_verify_result(ssl) != 0) return error.TlsCertificateInvalid;
        return .{ .ctx = ctx, .ssl = ssl, .fd = fd };
    }

    pub fn deinit(self: *Session) void {
        _ = SSL_shutdown(self.ssl);
        SSL_free(self.ssl);
        SSL_CTX_free(self.ctx);
    }

    pub fn readExact(self: *Session, io: std.Io, destination: []u8) !void {
        var used: usize = 0;
        while (used < destination.len) {
            try self.checkDeadline(io);
            const count: c_int = @intCast(@min(destination.len - used, std.math.maxInt(c_int)));
            ERR_clear_error();
            const n = SSL_read(self.ssl, destination[used..].ptr, count);
            if (n <= 0) {
                switch (SSL_get_error(self.ssl, n)) {
                    2 => { try waitReady(io, self.fd, poll_in); continue; },
                    3 => { try waitReady(io, self.fd, poll_out); continue; },
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
            try self.checkDeadline(io);
            const count: c_int = @intCast(@min(bytes.len - used, std.math.maxInt(c_int)));
            ERR_clear_error();
            const n = SSL_write(self.ssl, bytes[used..].ptr, count);
            if (n <= 0) {
                switch (SSL_get_error(self.ssl, n)) {
                    2 => { try waitReady(io, self.fd, poll_in); continue; },
                    3 => { try waitReady(io, self.fd, poll_out); continue; },
                    else => return error.TlsWriteFailed,
                }
            }
            used += @intCast(n);
        }
    }
};
