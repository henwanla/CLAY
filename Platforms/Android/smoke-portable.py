#!/usr/bin/env python3
"""Run an arm64 CLAY CLI on an explicitly selected Android emulator/device."""

import argparse
import base64
import json
from pathlib import Path
import re
import shlex
import subprocess
import tempfile
import uuid


SECRET_VALUES = (
    b"4624a73a-98ce-43e7-8868-4deba224779c",
    b"android-private-fixture.example.test",
    b"ANDROID_PRIVATE_LABEL",
    b"android-private-fixture-password",
)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("runtime", type=Path, help="libc++_shared.so from the same Android NDK used to build")
    parser.add_argument("--serial", required=True, help="adb device serial (e.g. emulator-5576)")
    parser.add_argument("--adb", default="adb")
    parser.add_argument("--adb-port", type=int, default=5037)
    cfg = parser.parse_args()
    if not re.fullmatch(r"[A-Za-z0-9_.:\[\]%-]+", cfg.serial) or not 1 <= cfg.adb_port <= 65535:
        parser.error("invalid adb serial or port")
    binary, runtime = cfg.binary.resolve(strict=True), cfg.runtime.resolve(strict=True)
    adb = [cfg.adb, "-P", str(cfg.adb_port), "-s", cfg.serial]

    def invoke(*args, expected=0):
        result = subprocess.run([*adb, *args], capture_output=True, timeout=60)
        if result.returncode != expected:
            raise RuntimeError(f"adb {args[0]} exit {result.returncode}; expected {expected}: {result.stderr.decode(errors='replace')}")
        return result.stdout.replace(b"\r\n", b"\n"), result.stderr

    def shell(command, *, expected=0):
        return invoke("shell", command, expected=expected)

    abi = shell("getprop ro.product.cpu.abilist")[0].decode().strip().split(",")
    if "arm64-v8a" not in abi:
        raise RuntimeError("Selected Android device does not report arm64-v8a support")
    api = shell("getprop ro.build.version.sdk")[0].decode().strip()
    if not api.isdecimal() or int(api) < 23:
        raise RuntimeError("The Android smoke test requires API 23 or later")

    remote = f"/data/local/tmp/clay-smoke-{uuid.uuid4().hex}"

    def run(*args, status=0):
        command = "LD_LIBRARY_PATH=" + remote + " " + shlex.join([remote + "/clay-portable", *args])
        out, err = shell(command, expected=status)
        if any(value in out + err for value in SECRET_VALUES):
            raise AssertionError("Private fixture value appeared in CLI output")
        if int(api) <= 24:
            # Older Android loaders report these two harmless NDK r30 ELF flags.
            loader_notes = {
                f"WARNING: linker: {remote}/clay-portable: unsupported flags DT_FLAGS_1=0x8000001".encode(),
                f"WARNING: linker: {remote}/libc++_shared.so: unused DT entry: type 0x70000001 arg 0x0".encode(),
            }
            err = b"\n".join(line for line in err.splitlines() if line not in loader_notes)
        if not status and err:
            raise AssertionError(f"Unexpected stderr from successful CLI check: {err.decode(errors='replace')}")
        return out

    shell(f"umask 077 && mkdir {remote}")
    try:
        invoke("push", str(binary), f"{remote}/clay-portable")
        invoke("push", str(runtime), f"{remote}/libc++_shared.so")
        shell(f"chmod 700 {remote}/clay-portable")
        with tempfile.TemporaryDirectory(prefix="clay-android-smoke-") as directory:
            def push(name, content):
                local = Path(directory) / name
                local.write_bytes(content)
                target = f"{remote}/{name}"
                invoke("push", str(local), target)
                return target

            node_id, host, label, password = (value.decode() for value in SECRET_VALUES)
            raw = {"ps": label, "add": host, "id": node_id, "port": "443", "tls": "tls"}
            vmess = base64.b64encode(json.dumps(raw).encode()).decode()
            nodes = push("节点 links.txt", (f"\ufeffvless://{node_id}@{host}:443?security=tls#{label}\r\n"
                         f"vmess://{vmess}\r\nss://aes-128-gcm:{password}@{host}:443#{label}\r\n"
                         f"trojan://{password}@{host}:443#{label}\r\nhttps://never-fetch.example.test/private\r\n").encode())
            assert run("inspect", nodes) == (b"nodes=4\nss/tcp/aead=1\ntrojan/tcp/tls=1\n"
                                              b"vless/tcp/tls=1\nvmess/tcp/tls=1\nskipped.unsupportedProtocol=1\n")
            yaml = push("Clash fixture.yaml", (f"proxy-providers:\n  ignored:\n    type: http\n"
                         f"    url: https://never-fetch.example.test/remote\nproxies:\n  - type: vless\n"
                         f"    server: {host}\n    port: 443\n    uuid: {node_id}\n    tls: true\n").encode())
            assert run("inspect", yaml) == b"nodes=1\nvless/tcp/tls=1\n"
            run("inspect", push("invalid input.txt", b"\xff\xfe"), status=65)
            pac = push("路由 pac.txt", b"DOMAIN-SUFFIX,example.test,DIRECT\n"
                        b"IP-CIDR,10.21.0.0/16,PROXY\nDOMAIN,2001:db8::10,DIRECT\n")
            assert run("pac-check", pac) == b"valid_pac_rules=3\n"
            assert run("pac-check", pac, "https://a.example.test/private") == b"decision=DIRECT source=rule:1\n"
            assert run("pac-check", pac, "10.21.1.5") == b"decision=PROXY source=rule:2\n"
            assert run("pac-check", pac, "[2001:db8::10]") == b"decision=DIRECT source=rule:3\n"
            assert run("pac-check", pac, "[::ffff:127.0.0.1]") == b"decision=DIRECT source=loopback\n"
            assert run("pac-check", pac, "elsewhere.test", "--default-direct") == b"decision=DIRECT source=default\n"
            script = run("pac-script", pac, "1080")
            assert b"function FindProxyForURL" in script and b"PROXY 127.0.0.1:1080" in script
            run("pac-script", pac, "0", status=64)
    finally:
        shell(f"rm -rf {remote}")
    print(f"PASS Android arm64 (API {api}) offline node inspection and PAC checks")


if __name__ == "__main__":
    main()
