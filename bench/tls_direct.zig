const std = @import("std");
const mysql = @import("zig_mysql");

// Diagnostic only: native crash stack in the failing thread without gdb
// scheduling changes. Not async-signal-safe under every libc implementation.
const SignalHandler = *const fn (c_int) callconv(.c) void;
extern "c" fn signal(c_int, SignalHandler) SignalHandler;
extern "c" fn backtrace([*]?*anyopaque, c_int) c_int;
extern "c" fn backtrace_symbols_fd([*]const ?*anyopaque, c_int, c_int) void;
extern "c" fn _exit(c_int) noreturn;

fn onFatal(sig: c_int) callconv(.c) void {
    var frames: [64]?*anyopaque = undefined;
    const n = backtrace(&frames, 64);
    backtrace_symbols_fd(&frames, n, 2);
    _exit(128 + sig);
}


const workers_count = 32;
const iterations = 128;

const Worker = struct {
    io: std.Io,
    allocator: std.mem.Allocator,
    failure: ?anyerror = null,

    fn work(self: *@This()) std.Io.Cancelable!void {
        self.execute() catch |err| {
            if (err == error.Canceled) return error.Canceled;
            self.failure = err;
        };
    }
    fn execute(self: *@This()) !void {
        var conn = try mysql.Client.connect(self.allocator, self.io, .{
            .address = .{ .ip = try std.Io.net.IpAddress.parseLiteral("127.0.0.1:33307") },
            .username = "root", .password = "zig_mysql_test", .database = "zigtest",
            .tls = .{
                .host = "MySQL_Server_8.4.11_Auto_Generated_Server_Certificate",
                .ca_file = "/tmp/zig-mysql-test-ca.pem",
            },
        });
        defer conn.deinit(self.io);
        // Handshake and authenticate 32 independent TLS sessions in parallel;
        // intentionally issue NO COM_QUERY to isolate connection lifecycle.
    }
};

fn oneRound(io: std.Io) !void {
    var workers: [workers_count]Worker = undefined;
    var group: std.Io.Group = .init;
    var joined = false;
    defer if (!joined) group.cancel(io);
    const started = std.Io.Clock.awake.now(io);
    for (&workers) |*w| {
        w.* = .{ .io = io, .allocator = std.heap.page_allocator };
        try group.concurrent(io, Worker.work, .{w});
    }
    try group.await(io);
    joined = true;
    for (&workers) |w| if (w.failure) |err| return err;
    const elapsed_ns: u64 = @intCast(@max(1, started.untilNow(io, .awake).toNanoseconds()));
    std.debug.print("TLS_HANDSHAKE_ONLY workers={d} handshakes={d} total_ms={d:.2}\\n",
        .{ workers_count, workers_count,
            @as(f64, @floatFromInt(elapsed_ns)) / 1e6 });
}

pub fn main(init: std.process.Init) !void {
    _ = signal(11, onFatal); // SIGSEGV
    _ = signal(6, onFatal); // SIGABRT
    // 128 rounds * 32 concurrent verified TLS handshakes, long enough for
    // live RSS/fd polling; detects failure that requires repeated sessions.
    for (0..128) |_| try oneRound(init.io);
}
