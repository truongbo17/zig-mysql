#!/usr/bin/env python3
"""Loopback-only deterministic MySQL wire stalls for timeout integration tests."""
import socketserver
import struct
import threading
import time


class ReusableServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


class NeverGreets(socketserver.BaseRequestHandler):
    def handle(self):
        time.sleep(2)


class NeverFinishesTls(socketserver.BaseRequestHandler):
    def handle(self):
        # HandshakeV10 with negotiated SSL/PROTOCOL_41/SECURE_CONNECTION/
        # PLUGIN_AUTH, sends server greeting but never the TLS ServerHello.
        capabilities = (1 << 9) | (1 << 11) | (1 << 15) | (1 << 19)
        greeting = (
            b"\x0a" + b"5.7.99-stall\x00" + struct.pack("<I", 1337)
            + b"abcdefgh" + b"\x00" + struct.pack("<H", capabilities & 0xffff)
            + b"\x2d" + b"\x02\x00" + struct.pack("<H", capabilities >> 16)
            + b"\x15" + bytes(10) + b"ijklmnopqrst\x00"
            + b"mysql_native_password\x00"
        )
        self.request.sendall(len(greeting).to_bytes(3, "little") + b"\x00" + greeting)
        self.request.settimeout(2)
        try:
            self.request.recv(128)  # Client SSLRequest
        except (TimeoutError, OSError):
            pass
        time.sleep(2)


if __name__ == "__main__":
    servers = [
        ReusableServer(("127.0.0.1", 33309), NeverGreets),
        ReusableServer(("127.0.0.1", 33310), NeverFinishesTls),
    ]
    threads = [threading.Thread(target=s.serve_forever, daemon=True) for s in servers]
    for thread in threads:
        thread.start()
    print("MySQL stall fixtures listening on 33309/33310", flush=True)
    try:
        while True:
            time.sleep(60)
    finally:
        for server in servers:
            server.shutdown()
            server.server_close()
