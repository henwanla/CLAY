#!/usr/bin/env python3
"""Synthetic CLI acceptance checks; no real proxy or subscription is used."""

import base64
import http.server
import json
import os
import pathlib
import subprocess
import sys
import tempfile
import threading


BINARY = pathlib.Path(sys.argv[1]).resolve(strict=True)
NODE_ID = "4624a73a-98ce-43e7-8868-4deba224779c"
NODE_LABEL = "SYNTHETIC_NODE_PRIVATE_TITLE"
NODE_HOST = "synthetic-node.example.test"
SECRET = b"portable-fixture-token"
NODE_PASSWORD = b"portable-fixture-password"
OBFS_PASSWORD = b"portable-fixture-obfs-password"
RESPONSE_PRIVATE = "DO_NOT_PRINT_CONTROLLER_CONNECTION"


def run(*args, data=None, code=0):
    result = subprocess.run([BINARY, *map(str, args)], input=data, capture_output=True, timeout=15,
                            env={**os.environ, "http_proxy": "http://127.0.0.1:1", "no_proxy": ""})
    assert result.returncode == code, (args[0], result.returncode, result.stderr)
    combined = result.stdout + result.stderr
    for value in (NODE_ID, NODE_LABEL, NODE_HOST, RESPONSE_PRIVATE):
        assert value.encode() not in combined, "sensitive value in CLI output"
    assert SECRET not in combined, "secret in CLI output"
    assert NODE_PASSWORD not in combined, "node password in CLI output"
    assert OBFS_PASSWORD not in combined, "obfuscation password in CLI output"
    assert not (code == 0 and result.stderr), "standard error on successful invocation"
    return result.stdout.replace(b"\r\n", b"\n")


def offline_checks(directory):
    node = f"vless://{NODE_ID}@{NODE_HOST}:443?security=tls#{NODE_LABEL}\n"
    vmess = {"ps": NODE_LABEL, "add": NODE_HOST, "id": NODE_ID, "port": "443", "tls": "tls"}
    vmess_url = b"vmess://" + base64.b64encode(json.dumps(vmess).encode())
    hy2_url = f"hy2://{NODE_PASSWORD.decode()}@{NODE_HOST}?obfs=salamander&obfs-password={OBFS_PASSWORD.decode()}#{NODE_LABEL}"
    tuic_url = f"tuic://{NODE_ID}%3A{NODE_PASSWORD.decode()}@{NODE_HOST}:443?udp_relay_mode=quic#{NODE_LABEL}"
    links = directory / "节点 profiles.txt"
    links.write_text("\ufeff" + "\n".join([node.rstrip(), vmess_url.decode(), hy2_url, tuic_url,
                                           "https://never-fetch.example.test/private", ""]), encoding="utf-8")
    assert run("inspect", links) == b"nodes=4\nhysteria2/quic/tls=1\ntuic/quic/tls=1\nvless/tcp/tls=1\nvmess/tcp/tls=1\nskipped.unsupportedProtocol=1\n"
    assert run("inspect", links, "--numbered") == (b"nodes=4\nnode=1 vless/tcp/tls\nnode=2 vmess/tcp/tls\nnode=3 hysteria2/quic/tls\nnode=4 tuic/quic/tls\n"
                                                   b"skipped.unsupportedProtocol=1\n")
    raw = links.read_bytes()
    assert run("inspect", "--profile-stdin", "--numbered", data=len(raw).to_bytes(4, "big") + raw) == run("inspect", links, "--numbered")
    for malformed in (b"", b"\0\0\x01", b"\0\0\0\0", b"\0\0\0\x02a", b"\0\0\0\x01\xff", (2_097_153).to_bytes(4, "big")):
        run("inspect", "--profile-stdin", data=malformed, code=65)
    run("inspect", links, "--unknown", code=64)
    yaml = directory / "profile.yaml"
    yaml.write_text(f"""proxy-providers:
  remote:
    type: http
    url: https://never-fetch.example.test/private
proxies:
  - name: {NODE_LABEL}
    type: vless
    server: {NODE_HOST}
    port: 443
    uuid: {NODE_ID}
    tls: true
  - type: ss
    name: {NODE_LABEL}
    server: {NODE_HOST}
    port: 443
    cipher: aes-128-gcm
    password: {NODE_PASSWORD.decode()}
  - type: trojan
    name: {NODE_LABEL}
    server: {NODE_HOST}
    port: 443
    password: {NODE_PASSWORD.decode()}
  - type: hysteria2
    name: {NODE_LABEL}
    server: {NODE_HOST}
    port: 443
    password: {NODE_PASSWORD.decode()}
    obfs: gecko
    obfs-password: {OBFS_PASSWORD.decode()}
  - type: tuic
    name: {NODE_LABEL}
    server: {NODE_HOST}
    port: 443
    uuid: {NODE_ID}
    password: {NODE_PASSWORD.decode()}
    udp-relay-mode: native
    reduce-rtt: false
  - type: unsupported-fixture
    name: Ignored
""", encoding="utf-8")
    assert run("inspect", yaml) == (b"nodes=5\nhysteria2/quic/tls=1\nss/tcp/aead=1\ntrojan/tcp/tls=1\ntuic/quic/tls=1\n"
                                     b"vless/tcp/tls=1\nskipped.unsupportedProtocol=1\n")
    assert run("inspect", yaml, "--numbered") == (b"nodes=5\nnode=1 vless/tcp/tls\nnode=2 ss/tcp/aead\n"
                                                  b"node=3 trojan/tcp/tls\nnode=4 hysteria2/quic/tls\nnode=5 tuic/quic/tls\n"
                                                  b"skipped.unsupportedProtocol=1\n")

    # JSON numbers 0/1 do not stand in for true/false, or vice versa.
    json_file = directory / "typed-fields.json"
    base = {"type": "vless", "server": NODE_HOST, "uuid": NODE_ID}
    json_file.write_text(json.dumps({"proxies": [
        {**base, "port": 1, "tls": False},
        {**base, "port": 443, "tls": True},
        {**base, "port": True},
        {**base, "port": False},
        {**base, "port": 443, "tls": 0},
        {**base, "port": 443, "tls": 1},
    ]}), encoding="utf-8")
    assert run("inspect", json_file) == (b"nodes=2\nvless/tcp/none=1\nvless/tcp/tls=1\n"
                                         b"skipped.invalidAccount=2\nskipped.malformed=2\n")
    invalid = directory / f"{NODE_LABEL}.txt"
    invalid.write_bytes(b"\xff\xfe")
    run("inspect", invalid, code=65)
    invalid.write_bytes(b"x" * (2 * 1024 * 1024 + 1))
    run("inspect", invalid, code=65)
    invalid.write_text("https://never-fetch.example.test/private\n", encoding="utf-8")
    run("inspect", invalid, code=65)
    run("inspect", directory, code=65)

    pac = directory / "路由 pac.txt"
    pac.write_text("""# synthetic
DOMAIN-SUFFIX,example.test,DIRECT
IP-CIDR,10.21.0.0/16,PROXY
DOMAIN,2001:db8::10,DIRECT
DOMAIN,::ffff:192.0.2.1,PROXY
""", encoding="utf-8")
    assert run("pac-check", pac) == b"valid_pac_rules=4\n"
    assert run("pac-check", pac, "https://a.example.test/private") == b"decision=DIRECT source=rule:1\n"
    assert run("pac-check", pac, "10.21.1.5") == b"decision=PROXY source=rule:2\n"
    assert run("pac-check", pac, "[2001:db8:0:0:0:0:0:0010]") == b"decision=DIRECT source=rule:3\n"
    assert run("pac-check", pac, "[::FFFF:C000:0201]") == b"decision=PROXY source=rule:4\n"
    assert run("pac-check", pac, "[::ffff:127.0.0.1]") == b"decision=DIRECT source=loopback\n"
    assert run("pac-check", pac, "[fe80::1%eth0]") == b"decision=DIRECT source=local\n"
    assert run("pac-check", pac, "[fc00::1]", "--no-local-bypass") == b"decision=PROXY source=default\n"
    assert run("pac-check", pac, "outside.test", "--default-direct") == b"decision=DIRECT source=default\n"
    for malformed in ("[:::1]", "[1::2::3]", "[1:2:3:4:5:6:7:8:9]", "[::ffff:192.000.2.1]", "[1:2:3:4:5:6:7:8::]"):
        run("pac-check", pac, malformed, code=65)
    script = run("pac-script", pac, 1080)
    assert b"function FindProxyForURL" in script and b"PROXY 127.0.0.1:1080" in script
    run("pac-script", pac, 0, code=64)
    pac.write_text("DOMAIN,a.example.test,DIRECT\nUNSUPPORTED,private.example.test,PROXY\n", encoding="utf-8")
    run("pac-script", pac, 1080, code=65)
    print("PASS offline node inspection, PAC validation and generation")


def desktop_bridge_checks(directory):
    args = [BINARY, "desktop-node-list", "--profile-stdin"]
    fixture = {"type": "ss", "port": 443, "server": NODE_HOST, "cipher": "aes-128-gcm", "password": NODE_PASSWORD.decode()}
    names = ["东京  東京\u202e  😄", "https://private.example.invalid/token", "雪" * 100]
    data = json.dumps({"proxies": [{**fixture, "name": name} for name in names]}).encode()
    frame = len(data).to_bytes(4, "big") + data
    reply = subprocess.run(args, input=frame, capture_output=True, timeout=15, check=True)
    rows = reply.stdout.splitlines()
    assert rows[0] == b"nodes=3" and len(rows) == 4 and not reply.stderr
    labels = []
    for index, row in enumerate(rows[1:], 1):
        index_field, kind, label = row.split(b" ")
        assert index_field == f"node={index}".encode() and kind == b"ss/tcp/aead"
        labels.append("" if label == b"-" else base64.b64decode(label, validate=True).decode("utf-8"))
    assert labels == ["东京 東京 😄", "", "雪" * 64]
    assert all(NODE_HOST.encode() not in label.encode() and NODE_PASSWORD not in label.encode() for label in labels)

    path = directory / "redirected-node-list.txt"
    with path.open("wb") as disk:
        result = subprocess.run(args, input=frame, stdout=disk, stderr=subprocess.PIPE, timeout=15)
    assert result.returncode == 65 and not path.read_bytes() and NODE_PASSWORD not in result.stderr
    path.write_bytes(frame)
    with path.open("rb") as disk:
        result = subprocess.run(args, stdin=disk, capture_output=True, timeout=15)
    assert result.returncode == 65 and not result.stdout and NODE_PASSWORD not in result.stderr
    print("PASS named desktop nodes through pipes and refusal of disk redirects")


class Fixture(http.server.BaseHTTPRequestHandler):
    requests = []
    redirect = False

    def log_message(self, *_):
        return

    def do_GET(self):
        self.requests.append(self.path)
        if self.headers.get("Authorization") != "Bearer " + SECRET.decode():
            self.send_error(401)
            return
        if self.redirect:
            self.send_response(302)
            self.send_header("Location", "/unexpected")
            self.end_headers()
            return
        body = json.dumps({"version": "fixture", "uploadTotal": 15, "downloadTotal": 49,
                           "connections": [{"host": RESPONSE_PRIVATE}]}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def controller_checks():
    with http.server.HTTPServer(("127.0.0.1", 0), Fixture) as server:
        worker = threading.Thread(target=server.serve_forever, daemon=True)
        worker.start()
        try:
            port = server.server_port
            assert run("mihomo-status", port, data=SECRET + b"\n") == b"mihomo=ready upload_bytes=15 download_bytes=49\n"
            assert Fixture.requests == ["/version", "/connections"]
            run("mihomo-status", port, data=b"wrong", code=69)
            assert Fixture.requests == ["/version", "/connections", "/version"]
            run("mihomo-status", port, data=b"bad\nheader", code=65)
            assert Fixture.requests == ["/version", "/connections", "/version"]
            Fixture.redirect = True
            run("mihomo-status", port, data=SECRET, code=69)
            assert Fixture.requests == ["/version", "/connections", "/version", "/version"]
        finally:
            server.shutdown()
            worker.join(timeout=5)
    print("PASS loopback Mihomo authentication, counters, and redirect rejection")


with tempfile.TemporaryDirectory(prefix="clay-portable-") as temp:
    offline_checks(pathlib.Path(temp))
    desktop_bridge_checks(pathlib.Path(temp))
if "--offline-only" not in sys.argv[2:]:
    controller_checks()
