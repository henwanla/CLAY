#!/usr/bin/env python3
"""Authenticated loopback origins for Relay instrumentation. Never dials a target."""

from base64 import b64encode
from contextlib import ExitStack
from hashlib import sha256
from pathlib import Path
import re
from secrets import token_hex
import socketserver
import ssl
from subprocess import DEVNULL, run
from threading import Event, Thread


proof, user, password = (token_hex(12) for _ in range(3))
auth = b"Basic " + b64encode(f"{user}:{password}".encode("ascii"))


def headers(stream):
    first = stream.readline(1024)
    values = {}
    for _ in range(24):
        line = stream.readline(2048)
        if line == b"\r\n":
            return first, values
        if not line.endswith(b"\r\n") or b":" not in line:
            break
        key, value = line.split(b":", 1)
        values[key.lower()] = value.strip()
    raise ValueError("invalid synthetic headers")


def connect_http(stream, peer):
    line, fields = headers(stream)
    if not re.fullmatch(rb"CONNECT 127\.0\.0\.1:[0-9]{1,5} HTTP/1\.[01]\r\n", line):
        return False
    if fields.get(b"proxy-authorization") != auth:
        peer.sendall(b"HTTP/1.1 407 Proxy Authentication Required\r\nContent-Length: 0\r\n\r\n")
        return False
    peer.sendall(b"HTTP/1.1 200 Connection Established\r\n\r\n")
    return True


def connect_socks(stream, peer):
    greeting = stream.read(2)
    if len(greeting) != 2 or greeting[0] != 5 or b"\x02" not in stream.read(greeting[1]):
        return False
    peer.sendall(b"\x05\x02")
    user_head = stream.read(2)
    if len(user_head) != 2 or user_head[0] != 1:
        return False
    supplied_user = stream.read(user_head[1])
    length = stream.read(1)
    if not length:
        return False
    supplied_password = stream.read(length[0])
    if (supplied_user, supplied_password) != (user.encode("ascii"), password.encode("ascii")):
        peer.sendall(b"\x01\x01")
        return False
    peer.sendall(b"\x01\x00")
    target = stream.read(10)
    if len(target) != 10 or not target.startswith(b"\x05\x01\x00\x01\x7f\x00\x00\x01"):
        return False
    peer.sendall(b"\x05\x00\x00\x01\x7f\x00\x00\x01\x00\x00")
    return True


class Fixture(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            self.request.settimeout(4)
            with ExitStack() as stack:
                peer = self.request
                if self.server.tls:
                    peer = stack.enter_context(self.server.tls.wrap_socket(peer, server_side=True))
                stream = stack.enter_context(peer.makefile("rb"))
                if not self.server.handshake(stream, peer):
                    return
                line, fields = headers(stream)
                if line not in (b"GET /test HTTP/1.1\r\n", b"GET /test HTTP/1.0\r\n") or b"proxy-authorization" in fields:
                    return
                body = f"{proof}-{self.server.variant}".encode("ascii")
                peer.sendall(f"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: {len(body)}\r\n\r\n".encode("ascii") + body)
        except (OSError, ValueError):
            pass  # Failed authentication or TLS probes can terminate mid-handshake.


def certificate():
    run(["openssl", "req", "-x509", "-newkey", "ec", "-pkeyopt", "ec_paramgen_curve:prime256v1",
         "-nodes", "-days", "1", "-subj", "/CN=CLAY relay fixture", "-out", "cert.pem", "-keyout", "key.pem"],
        stdout=DEVNULL, stderr=DEVNULL, check=True)
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain("cert.pem", "key.pem")
    Path("key.pem").unlink()
    return tls, sha256(ssl.PEM_cert_to_DER_cert(Path("cert.pem").read_text())).hexdigest()


def main():
    tls, pin = certificate()
    with ExitStack() as stack:
        ports = []
        for variant, (handshake, encryption) in enumerate(
                ((connect_http, None), (connect_socks, None), (connect_http, tls), (connect_socks, tls)), 1):
            server = stack.enter_context(socketserver.ThreadingTCPServer(("127.0.0.1", 0), Fixture))
            server.daemon_threads = True
            server.variant, server.handshake, server.tls = variant, handshake, encryption
            Thread(target=server.serve_forever, daemon=True).start()
            ports.append(str(server.server_address[1]))
        Path("fixture.tmp").write_text(",".join(ports + [proof, user, password, pin]) + "\n", encoding="ascii")
        Path("fixture.tmp").rename("fixture-ready")
        Event().wait()


if __name__ == "__main__":
    main()
