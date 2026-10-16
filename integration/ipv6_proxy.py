#!/usr/bin/env python3
"""Test-only dual-stack loopback relay: ::1:33311 -> 127.0.0.1:33306.

Avoids requiring an IPv6-enabled Docker bridge in GitHub Actions. The driver
still makes a real AF_INET6 TCP connection. Loopback-only, no public bind.
"""
import select
import socket
import socketserver


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        with socket.create_connection(("127.0.0.1", 33306), timeout=5) as backend:
            self.request.settimeout(None)
            backend.settimeout(None)
            peers = (self.request, backend)
            while True:
                readable, _, _ = select.select(peers, [], [], 10)
                for sock in readable:
                    data = sock.recv(65536)
                    if not data:
                        return
                    (backend if sock is self.request else self.request).sendall(data)


class Server(socketserver.ThreadingTCPServer):
    address_family = socket.AF_INET6
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    with Server(("::1", 33311), Handler) as server:
        print("E3_IPV6_PROXY_READY ::1:33311", flush=True)
        server.serve_forever()
