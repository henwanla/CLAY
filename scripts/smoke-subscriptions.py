#!/usr/bin/env python3
"""Exercise the actual subscription fetcher using only a loopback HTTP server."""
import argparse
import base64
from contextlib import ExitStack
import http.server
from pathlib import Path
import socketserver
import subprocess
import tempfile
import threading
from uuid import UUID


LINK = b"vless://4624a73a-98ce-43e7-8868-4deba224779c@127.0.0.1:1234#local"
CHUNK = b"a" * 65536
CHUNK_COUNT = 33
TEST_ACCOUNT = UUID("4624a73a-98ce-43e7-8868-4deba224779c").bytes


class RouteNode(socketserver.StreamRequestHandler):
    """Minimal VLESS TCP fixture that answers only the expected test destination."""

    def handle(self):
        self.connection.settimeout(8)
        try:
            header = b"\x00" + TEST_ACCOUNT + b"\x00\x01" + self.server.origin_port.to_bytes(2, "big") + b"\x01\x7f\x00\x00\x01"
            if self.rfile.read(len(header)) != header:
                return
            self.wfile.write(b"\x00\x00")
            while self.rfile.readline(512) == b"GET /keepalive HTTP/1.1\r\n":
                if self.rfile.readline(512) != b"Host: 127.0.0.1\r\n" or self.rfile.readline(4) != b"\r\n":
                    return
                self.wfile.write(b"HTTP/1.1 200 OK\r\nContent-Length: 5\r\n\r\n" + self.server.marker)
        except OSError:
            pass


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        route = self.path.partition("?")[0]
        if route == "/plain":
            self.send_body(LINK)
        elif route == "/keepalive":
            self.protocol_version = "HTTP/1.1"
            self.close_connection = False
            self.send_body(b"alive")
        elif route == "/base64":
            self.send_body(base64.b64encode(LINK))
        elif route == "/clash-yaml":
            with self.server.revision_lock:
                self.server.yaml_downloads += 1
            body = f"""\
proxies:
  - {{name: yaml, type: vless, server: 127.0.0.1, port: 1234, uuid: 4624a73a-98ce-43e7-8868-4deba224779c}}
proxy-providers:
  ignored:
    type: http
    url: http://127.0.0.1:{self.server.server_port}/unexpected-provider
"""
            self.send_body(body.encode("utf-8"))
        elif route == "/unexpected-provider":
            with self.server.revision_lock:
                self.server.provider_downloads += 1
            self.send_body(b"unexpected provider request", status=500)
        elif route == "/changing":
            with self.server.revision_lock:
                self.server.revision += 1
                revision = self.server.revision
            if revision == 1:
                self.send_body(LINK, cache_control="public, max-age=3600")
            elif revision == 2:
                self.send_body(LINK.replace(b"#local", b"#replaced"), cache_control="public, max-age=3600")
            else:
                self.send_body(b"unavailable", status=503)
        elif route == "/empty":
            self.send_body(b"unsupported://example")
        elif route == "/missing":
            self.send_body(b"missing", status=404)
        elif route == "/large":
            self.send_response(200)
            self.send_header("Content-Length", str(len(CHUNK) * CHUNK_COUNT))
            self.end_headers()
            self.send_large_body()
        elif route == "/stream-large":
            self.send_response(200)
            self.end_headers()
            self.send_large_body()
        elif route == "/redirect":
            self.redirect("/plain")
        elif route == "/bad-redirect":
            self.redirect("file:///clay-synthetic-subscription-do-not-read")
        elif route == "/cross-origin":
            self.redirect(f"http://localhost:{self.server.server_port}/unexpected-redirect")
        elif route == "/unexpected-redirect":
            with self.server.revision_lock:
                self.server.redirect_downloads += 1
            self.send_body(LINK)
        else:
            self.send_body(b"unknown route", status=404)

    def send_body(self, body, status=200, cache_control=None):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        if cache_control is not None:
            self.send_header("Cache-Control", cache_control)
        self.end_headers()
        self.wfile.write(body)

    def send_large_body(self):
        try:
            for _ in range(CHUNK_COUNT):
                self.wfile.write(CHUNK)
        except (BrokenPipeError, ConnectionResetError):
            pass  # Expected when the client cancels an oversized response.

    def redirect(self, target):
        self.send_response(302)
        self.send_header("Location", target)
        self.send_header("Content-Length", "0")
        self.end_headers()

    def log_message(self, *args):
        pass


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("checks", type=Path)
    parser.add_argument("--mihomo", type=Path, help="run the workspace checks with this engine instead of core checks")
    args = parser.parse_args()
    executable = args.checks.resolve(strict=True)
    engine = args.mihomo.resolve(strict=True) if args.mihomo else None
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Fixture) as server:
        server.revision = 0
        server.yaml_downloads = 0
        server.provider_downloads = 0
        server.redirect_downloads = 0
        server.revision_lock = threading.Lock()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}"
            if engine:
                with ExitStack() as stack:
                    tmp = stack.enter_context(tempfile.TemporaryDirectory(prefix="clay-workspace-"))
                    ports = []
                    for marker in (b"node1", b"node2"):
                        node = stack.enter_context(socketserver.ThreadingTCPServer(("127.0.0.1", 0), RouteNode))
                        node.daemon_threads = True
                        node.origin_port, node.marker = server.server_port, marker
                        threading.Thread(target=node.serve_forever, daemon=True).start()
                        stack.callback(node.shutdown)
                        ports.append(str(node.server_address[1]))
                    subprocess.run([executable, url, engine, Path(tmp) / "catalog", *ports], check=True, timeout=55)
            else:
                subprocess.run([executable, "--subscription-fixture", url], check=True, timeout=45)
                if server.yaml_downloads != 1:
                    raise RuntimeError("Subscription checks did not download the Clash YAML fixture exactly once.")
            if server.provider_downloads:
                raise RuntimeError("Subscription checks unexpectedly downloaded an embedded provider.")
            if server.redirect_downloads:
                raise RuntimeError("Subscription checks unexpectedly followed a cross-origin redirect.")
            if server.revision != 3:
                raise RuntimeError("Subscription checks did not make three fresh requests; rebuild CLAYCoreChecks.")
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
