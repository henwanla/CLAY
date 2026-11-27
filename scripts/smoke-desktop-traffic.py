#!/usr/bin/env python3
"""Exercise the packaged Windows/Linux runtime with a pinned engine on loopback."""

import hashlib
import http.client
import http.server
import json
import os
from pathlib import Path
from queue import Queue
import re
import secrets
import socket
import subprocess
import sys
import tempfile
import threading
import time


def run(cli, engine, digest):
    with engine.open("rb") as source:
        assert hashlib.file_digest(source, "sha256").hexdigest() == digest, "Wrong engine fixture"
    marker = secrets.token_hex(32).encode("ascii")
    password = secrets.token_hex(16)
    requests = Queue()

    class Origin(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            requests.put(self.path)
            self.send_response(200)
            self.send_header("Content-Length", str(len(marker)))
            self.end_headers()
            self.wfile.write(marker)

        def log_message(self, *_):
            pass

    with tempfile.TemporaryDirectory(prefix="clay-traffic-") as scratch, \
            http.server.ThreadingHTTPServer(("127.0.0.1", 0), Origin) as origin:
        directory = Path(scratch)
        threading.Thread(target=origin.serve_forever, daemon=True).start()
        with socket.socket() as reservation:
            reservation.bind(("127.0.0.1", 0))
            upstream_port = reservation.getsockname()[1]
        upstream_config = directory / "upstream.json"
        upstream_config.write_text(json.dumps({
            "mode": "rule", "log-level": "silent", "allow-lan": False, "ipv6": False,
            "geo-auto-update": False, "profile": {"store-selected": False},
            "listeners": [{"name": "fixture", "type": "shadowsocks", "listen": "127.0.0.1",
                           "port": str(upstream_port), "cipher": "aes-128-gcm", "password": password}],
            "rules": [f"AND,((IP-CIDR,127.0.0.1/32),(DST-PORT,{origin.server_port})),DIRECT", "MATCH,REJECT"],
        }), encoding="utf-8")
        profile = directory / "profiles.txt"
        profile.write_text("\n".join(
            f"ss://aes-128-gcm:{key}@127.0.0.1:{upstream_port}#{label}"
            for key, label in ((password, "working"), (secrets.token_hex(16), "wrong-key"))
        ), encoding="utf-8")
        rules = directory / "rules.txt"
        rules.write_text("# Local destinations follow the standard direct exception in Rule mode.\n", encoding="utf-8")
        env = {key: os.environ[key] for key in ("SystemRoot", "WINDIR", "LOCALAPPDATA", "USERPROFILE", "TEMP", "TMP")
               if key in os.environ}
        # Windows needs the runner's verified Swift runtime on PATH.
        env.update({"HOME": scratch, "PATH": os.environ["PATH"] if os.name == "nt" else "/usr/bin:/bin"})
        with subprocess.Popen([engine, "-d", directory, "-f", upstream_config], cwd=directory, env=env,
                              stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL) as upstream:
            try:
                for _ in range(100):
                    assert upstream.poll() is None, "Local upstream exited"
                    try:
                        with socket.create_connection(("127.0.0.1", upstream_port), timeout=0.1):
                            break
                    except OSError:
                        time.sleep(0.05)
                else:
                    raise AssertionError("Local upstream did not bind")
                args = [cli, "mihomo-run", profile, "1", engine, digest, "--interactive", "--all-nodes", "--mode", "global",
                        "--pac-rules", rules]
                with subprocess.Popen(args, cwd=directory, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                      stderr=subprocess.DEVNULL) as client:
                    try:
                        exercise(client, origin.server_port, marker, requests)
                    finally:
                        if not client.stdin.closed:
                            client.stdin.close()
                        stop(client)
            finally:
                stop(upstream, terminate=True)
                origin.shutdown()


def stop(child, terminate=False):
    if terminate and child.poll() is None:
        child.terminate()
    try:
        child.wait(timeout=6)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait(timeout=5)
        raise AssertionError("Engine did not stop on time") from None


def exercise(client, origin_port, marker, requests):
    lines = Queue()

    def read():
        while row := client.stdout.readline(257):
            lines.put(row.strip())
        lines.put(None)

    threading.Thread(target=read, daemon=True).start()
    ready = re.fullmatch(rb"mihomo=ready proxy=127\.0\.0\.1:(\d+) controller=127\.0\.0\.1:\d+", lines.get(timeout=20) or b"")
    assert ready, "CLAY did not confirm a loopback session with the official engine"
    port = int(ready[1])

    def command(text):
        client.stdin.write(text + b"\n")
        client.stdin.flush()
        return lines.get(timeout=10)

    def sample():
        row = re.fullmatch(rb"traffic=up:([0-9]{1,19}) down:([0-9]{1,19})", command(b"traffic") or b"")
        assert row, "No aggregate traffic sample from the official engine"
        return tuple(map(int, row.groups()))

    def probe(label, expected):
        path = f"/{label}"
        connection = http.client.HTTPConnection("127.0.0.1", port, timeout=5)
        try:
            connection.request("GET", f"http://127.0.0.1:{origin_port}{path}", headers={"Connection": "close"})
            response = connection.getresponse()
            assert (response.status == 200 and response.read(1024) == marker) == expected, f"Unexpected response: {label}"
        except (ConnectionError, http.client.RemoteDisconnected):
            assert not expected, f"No successful response: {label}"
        finally:
            connection.close()
        if expected:
            assert requests.get(timeout=3) == path
        else:
            # If the runtime fell back to direct, the origin would already have received this request.
            assert requests.empty(), "A failed proxy credentials check contacted the original destination"

    assert command(b"status") == b"mode=global node=1", "Global startup mode not confirmed"
    assert sample() == (0, 0), "Idle session reported traffic"
    probe("global", True)
    up, down = sample()
    assert up > 0 and down >= len(marker), "Counters did not register real forwarded bytes"
    assert command(b"node 2") == b"node=2", "Node change not confirmed"
    probe("wrong-key", False)
    assert command(b"mode direct") == b"mode=direct", "Direct mode change not confirmed"
    probe("direct", True)
    assert command(b"mode rule") == b"mode=rule", "Rule mode change not confirmed"
    probe("local-rule", True)
    assert command(b"node 1") == b"node=1", "Working node did not recover"
    assert command(b"mode global") == b"mode=global", "Could not return to Global mode"
    probe("global-again", True)
    assert sample()[1] > down, "Traffic total unexpectedly reset when changing modes"
    client.stdin.close()
    assert client.wait(timeout=6) == 0, "CLAY did not clean up the loopback session"
    print("PASS official Mihomo: live loopback traffic, node and mode switching, counters and no fallback")


if __name__ == "__main__":
    _, cli_path, engine_path, fingerprint = sys.argv
    run(Path(cli_path).resolve(strict=True), Path(engine_path).resolve(strict=True), fingerprint)
