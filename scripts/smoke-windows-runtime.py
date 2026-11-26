#!/usr/bin/env python3
"""Native Windows process, ACL, and loopback checks with a synthetic engine."""
import ctypes
import hashlib
import json
import os
from pathlib import Path
import queue
import re
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import threading


def main(cli: Path, fixture: Path):
    kernel = ctypes.windll.kernel32
    console_members = (ctypes.c_ulong * 1)()
    if kernel.GetConsoleProcessList(console_members, 1) == 0 and not kernel.AllocConsole():
        raise RuntimeError("Could not allocate a test console for Ctrl-Break")
    root = Path(os.environ["LOCALAPPDATA"])
    existing = set(root.glob("clay-win-" + "?" * 32))
    env = dict(os.environ, CLAY_WINDOWS_TEST_MARKER="must-not-be-inherited")
    with tempfile.TemporaryDirectory(prefix="CLAY fixture ") as name:
        folder = Path(name)
        engine = folder / "fixture core 測試.exe"
        shutil.copyfile(fixture, engine)
        digest = hashlib.sha256(engine.read_bytes()).hexdigest().upper()
        profile = folder / "profile 測試.txt"
        rules = folder / "PAC rules.txt"
        rules.write_text("DOMAIN-SUFFIX,example.invalid,DIRECT\n", encoding="utf-8")

        def command(password, sha=digest, *extra):
            profile.write_text(f"ss://aes-128-gcm:{password}@example.invalid:443#synthetic\n", encoding="utf-8")
            return [str(cli), "mihomo-run", str(profile), "1", str(engine), sha,
                    "--mode", "global", "--pac-rules", str(rules), *extra]

        def bad(password, status, message, sha=digest, extra=()):
            process = subprocess.run(command(password, sha, *extra), env=env, capture_output=True, text=True, timeout=20)
            assert process.returncode == status, (message, process.returncode)
            assert not process.stdout and message in process.stderr, message
            assert all(item not in process.stderr for item in (password, "fixture-child-output", "external-controller", name))
            assert set(root.glob("clay-win-" + "?" * 32)) == existing, "failed session left private files"

        bad("valid-dummy", 65, "verification failed", "0" * 64)
        with socket.socket() as occupied:
            occupied.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            bad("valid-dummy", 69, "ports are unavailable", extra=("--proxy-port", str(occupied.getsockname()[1])))
        bad("exit-only-dummy", 69, "exited before")
        bad("wildcard-dummy", 69, "own loopback listeners")
        bad("split-owner-dummy", 69, "own loopback listeners")

        process = subprocess.Popen(command("valid-dummy"), env=env, text=True, stdout=subprocess.PIPE,
                                   stderr=subprocess.PIPE, creationflags=subprocess.CREATE_NEW_PROCESS_GROUP)
        try:
            out = queue.Queue()
            threading.Thread(target=lambda: out.put(process.stdout.readline()), daemon=True).start()
            line = out.get(timeout=14)
            match = re.fullmatch(r"mihomo=ready proxy=127\.0\.0\.1:(\d+) controller=127\.0\.0\.1:(\d+)\n", line)
            assert match, ("readiness", process.poll())
            ports = [int(p) for p in match.groups()]
            for port in ports:
                with socket.create_connection(("127.0.0.1", port), timeout=2) as connection:
                    connection.sendall(b"GET http://example.invalid/ HTTP/1.1\r\nHost: example.invalid\r\n\r\n")
                    response = connection.makefile("rb").read()
                    assert response.endswith(b"\r\n\r\nfixture"), "fixture response missing"
            dirs = set(root.glob("clay-win-" + "?" * 32)) - existing
            assert len(dirs) == 1, "wrong runtime directory count"
            runtime = dirs.pop()
            config_path = runtime / "clay.json"
            config = json.loads(config_path.read_text(encoding="utf-8"))
            assert re.fullmatch(r"[0-9a-f]{64}", config["secret"]), "controller key not generated"
            assert config["bind-address"] == "127.0.0.1" and not config["allow-lan"] and not config["tun"]["enable"]
            assert hashlib.sha256((runtime / "mihomo.exe").read_bytes()).hexdigest().upper() == digest
            verify_acl = r"""
$owner = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
foreach ($path in @($env:CLAY_ACL_DIR, $env:CLAY_ACL_FILE)) {
  $acl = Get-Acl -LiteralPath $path
  if ($path -eq $env:CLAY_ACL_DIR -and -not $acl.AreAccessRulesProtected) { exit 1 }
  if ($acl.Access.Count -ne 1 -or $acl.Access[0].IdentityReference.Translate([System.Security.Principal.SecurityIdentifier]).Value -ne $owner) { exit 2 }
}
"""
            acl = subprocess.run(["pwsh", "-NoProfile", "-Command", verify_acl],
                                 env=dict(env, CLAY_ACL_DIR=str(runtime), CLAY_ACL_FILE=str(config_path)),
                                 capture_output=True, timeout=10)
            assert acl.returncode == 0, "wrong Windows runtime ACL"
            process.send_signal(signal.CTRL_BREAK_EVENT)
            assert process.wait(timeout=10) == 130, "Ctrl-Break did not stop the session"
            assert not process.stdout.read() and not process.stderr.read(), "child output leaked"
            assert not runtime.exists(), "runtime directory remains"
            for port in ports:
                with socket.socket() as connection:
                    connection.settimeout(1)
                    assert connection.connect_ex(("127.0.0.1", port)) != 0, "listener remains"
        finally:
            if process.poll() is None:
                process.send_signal(signal.CTRL_BREAK_EVENT)
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
    print("Windows runtime smoke passed: verified engine, private ACL, owned loopback traffic, and cleanup")


if __name__ == "__main__":
    main(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
