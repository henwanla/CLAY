"""Loopback-only VLESS and HTTP fixtures, called by smoke-vpn.sh. No network forwarding."""
from pathlib import Path
from secrets import token_hex
from socketserver import StreamRequestHandler, ThreadingTCPServer
from threading import Event, Thread
from uuid import UUID

proof = token_hex(12)


class Request(StreamRequestHandler):
    def read_request(self):
        self.connection.settimeout(3)
        line = self.rfile.readline(512).strip()
        for _ in range(30):
            if self.rfile.readline(4096) == b"\r\n":
                return line
        return None

    def handle(self):
        try:
            if self.server.kind != "D":
                # VLESS v0, fixed synthetic UUID, no addons, TCP, fixed destination.
                header = b"\x00" + UUID("56dc6c3e-8793-4d37-a363-f9f19db29c6d").bytes + bytes.fromhex("000146a001c633642a")
                if self.rfile.read(len(header)) != header:
                    return
                self.wfile.write(b"\x00\x00")
            request = self.read_request()
            if request == b"GET /clay-vpn HTTP/1.0":
                body = f"{proof}-{self.server.kind}".encode("ascii")
                self.wfile.write(f"HTTP/1.0 200 OK\r\nContent-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
        except OSError:
            pass


with ThreadingTCPServer(("127.0.0.1", 0), Request) as a, \
        ThreadingTCPServer(("127.0.0.1", 0), Request) as b, \
        ThreadingTCPServer(("127.0.0.1", 0), Request) as d:
    a.kind, b.kind, d.kind = "A", "B", "D"
    for server in (a, b, d):
        Thread(target=server.serve_forever, daemon=True).start()
    Path("fixture-result").write_text(f"{a.server_address[1]} {b.server_address[1]} {d.server_address[1]} {proof}\n")
    Event().wait()
