"""Loopback-only TCP and DNS responses for smoke-vpn.sh; nothing is forwarded."""
from pathlib import Path
from secrets import token_hex
from socket import AF_INET6
from socketserver import StreamRequestHandler, ThreadingTCPServer
from struct import pack, unpack
from threading import Event, Thread
from uuid import UUID

proof = token_hex(12)
uuid = UUID("56dc6c3e-8793-4d37-a363-f9f19db29c6d").bytes
# XUDP endpoint: UDP port 53, IPv4 198.51.100.53 (documentation-only range).
dns_target = bytes.fromhex("02003501c6336435")
label = f"clay-{proof}".encode("ascii")
question = bytes([len(label)]) + label + b"\x04test\x00\x00\x01\x00\x01"



class Request(StreamRequestHandler):
    def read_request(self):
        self.connection.settimeout(3)
        line = self.rfile.readline(512).strip()
        for _ in range(30):
            if self.rfile.readline(4096) == b"\r\n":
                return line
        return None

    def respond_dns(self):
        size = self.rfile.read(2)
        if len(size) != 2:
            return
        length, = unpack("!H", size)
        if length not in (12, 20):  # Initial XUDP datagram, optionally with the 8-byte global ID.
            return
        header = self.rfile.read(length)
        if header[:12] != b"\x00\x00\x01\x01" + dns_target:
            return
        size = self.rfile.read(2)
        if size != pack("!H", 12 + len(question)):
            return
        query = self.rfile.read(12 + len(question))
        if query[2:12] != pack("!HHHHH", 0x0100, 1, 0, 0, 0) or query[12:] != question:
            return
        octet = 73 if self.server.kind == "A" else 74
        answer = pack("!HHHIHBBBB", 0xc00c, 1, 1, 0, 4, 203, 0, 113, octet)
        dns = query[:2] + pack("!HHHHH", 0x8180, 1, 1, 0, 0) + question + answer
        header = b"\x00\x00\x02\x01" + dns_target
        self.wfile.write(b"\x00\x00" + pack("!H", len(header)) + header + pack("!H", len(dns)) + dns)

    def handle(self):
        try:
            if self.server.kind in ("A", "B"):
                # VLESS v0, no addons. Accept only the two fixed proof destinations.
                prefix = b"\x00" + uuid + b"\x00"
                if self.rfile.read(len(prefix)) != prefix:
                    return
                command = self.rfile.read(1)
                if command == b"\x03":
                    self.respond_dns()
                    return
                if command != b"\x01" or self.rfile.read(7) != bytes.fromhex("46a001c633642a"):
                    return
                self.wfile.write(b"\x00\x00")
            request = self.read_request()
            if request == b"GET /clay-vpn HTTP/1.0":
                body = f"{proof}-{self.server.kind}".encode("ascii")
                self.wfile.write(f"HTTP/1.0 200 OK\r\nContent-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
        except OSError:
            pass


class LocalIPv6Server(ThreadingTCPServer):
    address_family = AF_INET6


with ThreadingTCPServer(("127.0.0.1", 0), Request) as a, \
        ThreadingTCPServer(("127.0.0.1", 0), Request) as b, \
        ThreadingTCPServer(("127.0.0.1", 0), Request) as d, \
        LocalIPv6Server(("::1", 0), Request) as ipv6:
    a.kind, b.kind, d.kind, ipv6.kind = "A", "B", "D", "V6"
    for server in (a, b, d, ipv6):
        Thread(target=server.serve_forever, daemon=True).start()
    Path("fixture-result").write_text(" ".join(str(s.server_address[1]) for s in (a, b, d, ipv6)) + f" {proof}\n")
    Event().wait()
