"""Loopback-only TCP and UDP responses for smoke-vpn.sh; nothing is forwarded."""
from base64 import b64encode
from pathlib import Path
from secrets import token_hex
from ipaddress import IPv6Address
from socket import AF_INET6
from socketserver import BaseRequestHandler, StreamRequestHandler, ThreadingTCPServer, UDPServer
from ssl import PROTOCOL_TLS_SERVER, SSLContext
from struct import pack, unpack
from subprocess import DEVNULL, run
from threading import Event, Thread
from uuid import UUID

proof = token_hex(12)
uuid = UUID("56dc6c3e-8793-4d37-a363-f9f19db29c6d").bytes
# Synthetic XUDP port 53 in each documentation range; no real DNS upstream.
dns_targets = (bytes.fromhex("02003501c6336435"),
               bytes.fromhex("02003503") + IPv6Address("2001:db8::53").packed)
label = f"clay-{proof}".encode("ascii")
question = bytes([len(label)]) + label + b"\x04test\x00\x00\x01\x00\x01"
labels_by_target = {target: tuple(f"{action}-{family}-{proof}" for action in ("proxy", "direct"))
                    for target, family in zip(dns_targets, ("v4", "v6"))}
names_by_target = {target: tuple(bytes([len(name)]) + name.encode("ascii") + b"\x04test\x00" for name in labels)
                   for target, labels in labels_by_target.items()}


def tls_context():
    # Ephemeral certificate for the synthetic names. The Android test
    # trusts this certificate in its own SSLContext, never at the system level.
    Path("tls.cnf").write_text("[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n"
                              "[dn]\nCN=CLAY loopback fixture\n[ext]\nsubjectAltName=" +
                              ",".join(f"DNS:{name}.test" for labels in labels_by_target.values() for name in labels) + "\n")
    run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
         "-nodes", "-days", "1", "-config", "tls.cnf", "-out", "tls.pem", "-keyout", "tls-key.pem"],
        stdout=DEVNULL, stderr=DEVNULL, check=True)
    context = SSLContext(PROTOCOL_TLS_SERVER)
    context.load_cert_chain("tls.pem", "tls-key.pem")
    Path("tls-key.pem").unlink()
    return context, b64encode(Path("tls.pem").read_bytes()).decode("ascii")


class Request(StreamRequestHandler):
    def reply(self, stream, connection):
        line = stream.readline(512).strip()
        for _ in range(30):
            if stream.readline(4096) == b"\r\n":
                if line in (b"GET /clay-vpn HTTP/1.0", b"GET /clay-vpn HTTP/1.1"):
                    body = f"{proof}-{self.server.kind}".encode("ascii")
                    connection.sendall(f"HTTP/1.0 200 OK\r\nContent-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
                return

    def read_header(self, size):
        # Do not buffer past the VLESS header; a ClientHello can follow it in
        # the same TCP segment and must remain available to the SSL socket.
        result = b""
        while len(result) < size:
            chunk = self.connection.recv(size - len(result))
            if not chunk:
                break
            result += chunk
        return result

    def respond_dns(self):
        size = self.rfile.read(2)
        if len(size) != 2:
            return
        length, = unpack("!H", size)
        if length not in (12, 20, 24, 32):  # Initial XUDP datagram, optionally with the 8-byte global ID.
            return
        header = self.rfile.read(length)
        dns_target = next((target for target in dns_targets
                           if length in (4 + len(target), 12 + len(target))
                           and header.startswith(b"\x00\x00\x01\x01" + target)), None)
        if dns_target is None:
            return
        size = self.rfile.read(2)
        if len(size) != 2:
            return
        length, = unpack("!H", size)
        if not 16 <= length <= 512:
            return
        query = self.rfile.read(length)
        if query[4:10] != pack("!HHH", 1, 0, 0):
            return
        qname = next((name for name in names_by_target[dns_target] if query[12:].startswith(name)), None)
        answer = b""
        if query[12:] == question:
            query_question = question
            address = (203, 0, 113, 73 if self.server.kind == "A" else 74)
        elif qname is not None:
            query_question = query[12:16 + len(qname)]
            qtype = query_question[len(qname):]
            if qtype == b"\x00\x01\x00\x01":
                address = (10, 0, 2, 2)
            elif qtype == b"\x00\x1c\x00\x01":
                address = None  # IPv6 NODATA for the IPv4-only fixture.
            else:
                return
        else:
            return
        if address is not None:
            answer = pack("!HHHIHBBBB", 0xc00c, 1, 1, 0, 4, *address)
        dns = query[:2] + pack("!HHHHH", 0x8180, 1, bool(answer), 0, 0) + query_question + answer
        header = b"\x00\x00\x02\x01" + dns_target
        self.wfile.write(b"\x00\x00" + pack("!H", len(header)) + header + pack("!H", len(dns)) + dns)

    def handle(self):
        try:
            self.connection.settimeout(4)
            tls = self.server.kind == "TLS-D"
            if self.server.kind in ("A", "B"):
                # VLESS v0, no addons. Accept only original IP/port pairs, never names.
                prefix = b"\x00" + uuid + b"\x00"
                if self.read_header(len(prefix)) != prefix:
                    return
                command = self.read_header(1)
                if command == b"\x03":
                    self.respond_dns()
                    return
                if command != b"\x01":
                    return
                address_head = self.read_header(3)
                if len(address_head) != 3 or address_head[2] not in (1, 3):
                    return
                target = address_head + self.read_header(4 if address_head[2] == 1 else 16)
                tls = target == self.server.tls_target
                if not tls and target not in self.server.http_targets:
                    return
                self.wfile.write(b"\x00\x00")
            if tls:
                with self.server.tls_context.wrap_socket(self.connection, server_side=True) as sock, sock.makefile("rb") as stream:
                    self.reply(stream, sock)
            else:
                self.reply(self.rfile, self.connection)
        except OSError:
            pass


class LocalIPv6Server(ThreadingTCPServer):
    address_family = AF_INET6


class DatagramOrigin(BaseRequestHandler):
    def handle(self):
        data, sock = self.request
        if data == f"blocked-{proof}".encode("ascii"):
            Path("unexpected-direct-udp").touch()
        elif data != f"direct-{proof}".encode("ascii"):
            return
        sock.sendto(data, self.client_address)


class LocalIPv6UDPServer(UDPServer):
    address_family = AF_INET6


def web_server(ports):
    for port in ports:
        try:
            return ThreadingTCPServer(("127.0.0.1", port), Request)
        except OSError:
            continue
    raise RuntimeError("could not allocate a local web fixture port")


with ThreadingTCPServer(("127.0.0.1", 0), Request) as a, \
        LocalIPv6Server(("::1", 0), Request) as b, \
        web_server((8000, 8080, 8081, 8888)) as d, \
        LocalIPv6Server(("::1", 0), Request) as ipv6, \
        LocalIPv6Server(("::1", 0), Request) as origin_only, \
        UDPServer(("127.0.0.1", 0), DatagramOrigin) as udp4, \
        LocalIPv6UDPServer(("::1", 0), DatagramOrigin) as udp6, \
        web_server((8443, 9443)) as t:
    a.kind, b.kind, d.kind, ipv6.kind, origin_only.kind, t.kind = "A", "B", "D", "V6", "V6-ORIGIN", "TLS-D"
    a.http_targets = b.http_targets = {
        bytes.fromhex("46a001c633642a"), pack("!HBBBBB", d.server_address[1], 1, 10, 0, 2, 2),
        *(pack("!HB", ipv6.server_address[1], 3) + IPv6Address(host).packed for host in ("fec0::2", "2001:db8::42")),
    }
    a.tls_target = b.tls_target = pack("!HBBBBB", t.server_address[1], 1, 10, 0, 2, 2)
    context, cert = tls_context()
    a.tls_context = b.tls_context = t.tls_context = context
    servers = (a, b, d, ipv6, t, origin_only, udp4, udp6)
    for server in servers:
        Thread(target=server.serve_forever, daemon=True).start()
    Path("fixture-result.tmp").write_text(" ".join(str(s.server_address[1]) for s in servers) + f" {proof} {cert}\n")
    Path("fixture-result.tmp").rename("fixture-result")
    Event().wait()
