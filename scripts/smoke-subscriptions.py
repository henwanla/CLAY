#!/usr/bin/env python3
"""Exercise the actual subscription fetcher using only a loopback HTTP server."""
import argparse
import base64
import http.server
from pathlib import Path
import subprocess
import tempfile
import threading


LINK = b"vless://4624a73a-98ce-43e7-8868-4deba224779c@127.0.0.1:1234#local"
CHUNK = b"a" * 65536
CHUNK_COUNT = 33


class Fixture(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        route = self.path.partition("?")[0]
        if route == "/plain":
            self.send_body(LINK)
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
        server.revision_lock = threading.Lock()
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            url = f"http://127.0.0.1:{server.server_port}"
            if engine:
                with tempfile.TemporaryDirectory(prefix="clay-workspace-") as tmp:
                    subprocess.run([executable, url, engine, Path(tmp) / "catalog"], check=True, timeout=45)
            else:
                subprocess.run([executable, "--subscription-fixture", url], check=True, timeout=45)
                if server.yaml_downloads != 1:
                    raise RuntimeError("Subscription checks did not download the Clash YAML fixture exactly once.")
            if server.provider_downloads:
                raise RuntimeError("Subscription checks unexpectedly downloaded an embedded provider.")
            if server.revision != 3:
                raise RuntimeError("Subscription checks did not make three fresh requests; rebuild CLAYCoreChecks.")
        finally:
            server.shutdown()
            thread.join()


if __name__ == "__main__":
    main()
