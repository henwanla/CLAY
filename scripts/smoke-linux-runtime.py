#!/usr/bin/env python3
"""Linux-only subprocess, socket ownership, and cleanup checks with a synthetic engine."""

import hashlib
import os
from pathlib import Path
import re
import selectors
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time


ENGINE = '''#!/usr/bin/python3
import json
import os
from pathlib import Path
import signal
import socket
import stat
import sys
import time

directory = Path(sys.argv[sys.argv.index("-d") + 1])
config_file = Path(sys.argv[sys.argv.index("-f") + 1])
config = json.loads(config_file.read_text())
assert stat.S_IMODE(directory.stat().st_mode) == 0o700
assert stat.S_IMODE(config_file.stat().st_mode) == 0o600
assert os.environ["HOME"] == str(directory)
assert os.environ["XDG_CONFIG_HOME"] == str(directory)
assert "HTTP_PROXY" not in os.environ and "LD_PRELOAD" not in os.environ
assert config["allow-lan"] is False and config["bind-address"] == "127.0.0.1"
assert config["tun"]["enable"] is False and config["rules"] == ["MATCH,CLAY"]
assert config["secret"] and len(config["proxies"]) == 1
assert config["proxies"][0]["password"] == "synthetic-selected"
proxy_port = config["mixed-port"]
control_port = int(config["external-controller"].split(":")[-1])
Path(REPORT).write_text(json.dumps([str(directory), os.getpid(), proxy_port, control_port]))
if MODE == "exit":
    sys.exit(2)
if MODE == "ignore-term":
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
sockets = []
if MODE not in {"none", "exit"}:
    for port in [proxy_port, control_port]:
        listener = socket.socket()
        listener.bind(("127.0.0.1" if MODE != "wildcard" else "0.0.0.0", port))
        listener.listen()
        sockets.append(listener)
while True:
    time.sleep(0.2)
'''


def wait_until(action, seconds=18):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        if result := action():
            return result
        time.sleep(0.03)
    raise AssertionError("fixture did not reach expected state")


def run_checks(binary):
    import json

    with tempfile.TemporaryDirectory(prefix="clay-linux-check-") as scratch:
        scratch = Path(scratch)
        profiles = scratch / "profiles.txt"
        profiles.write_text("ss://aes-128-gcm:unused@127.0.0.1:9001#first\n"
                            "trojan://synthetic-selected@127.0.0.1:9002#second\n")
        engine, report_file = scratch / "engine", scratch / "report.json"

        def command(mode, *flags, index="2", digest=None):
            report_file.unlink(missing_ok=True)
            source = f'MODE = {mode!r}\nREPORT = {str(report_file)!r}\n'
            script = ENGINE.replace("import json\n", source + "import json\n", 1)
            engine.write_text(script)
            engine.chmod(0o700)
            fingerprint = digest or hashlib.sha256(engine.read_bytes()).hexdigest()
            return [binary, "mihomo-run", str(profiles), index, str(engine), fingerprint, *flags]

        def launch(mode, *flags):
            return subprocess.Popen(command(mode, *flags), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                                    stderr=subprocess.PIPE, text=True, env={**os.environ, "HTTP_PROXY": "not-used"})

        def report():
            try:
                return json.loads(report_file.read_text())
            except (FileNotFoundError, ValueError):
                return None

        def clean(directory, pid):
            assert not Path(directory).exists(), "private runtime directory remains"
            assert not Path(f"/proc/{pid}").exists(), "owned child was not reaped"

        def finish(process):
            # Always tear down a test failure without leaving the synthetic
            # child or its runtime directory on the runner.
            if process.poll() is None:
                process.terminate()
            try:
                return process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                process.kill()
                return process.communicate(timeout=3)

        for mode, stop_signal in [("normal", signal.SIGINT), ("ignore-term", signal.SIGTERM)]:
            process = launch(mode)
            try:
                directory, pid, proxy, control = wait_until(report)
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    assert selector.select(timeout=5), "runtime did not announce readiness"
                    line = process.stdout.readline()
                assert re.fullmatch(r"mihomo=ready proxy=127\.0\.0\.1:\d+ controller=127\.0\.0\.1:\d+\n", line), line
                assert line == f"mihomo=ready proxy=127.0.0.1:{proxy} controller=127.0.0.1:{control}\n"
                for port in (proxy, control):
                    with socket.create_connection(("127.0.0.1", port), timeout=2):
                        pass
                process.send_signal(stop_signal)
                tail, stderr = process.communicate(timeout=5)
                assert not tail and not stderr
                assert process.returncode == 128 + stop_signal
                clean(directory, pid)
            finally:
                finish(process)

        # The engine never binds. Inject listener sockets from a different
        # process after reservation release; the runtime must not report ready.
        process = launch("none")
        try:
            directory, pid, proxy, control = wait_until(report)
            with socket.socket() as a, socket.socket() as b:
                for listener, port in ((a, proxy), (b, control)):
                    listener.bind(("127.0.0.1", port))
                    listener.listen()
                stdout, stderr = process.communicate(timeout=9)
            assert process.returncode == 69 and not stdout and "own loopback listeners" in stderr
            clean(directory, pid)
        finally:
            finish(process)

        for mode, diagnostic in (("exit", "exited"), ("wildcard", "own loopback listeners")):
            process = launch(mode)
            try:
                directory, pid, _, _ = wait_until(report)
                stdout, stderr = process.communicate(timeout=9)
                assert process.returncode == 69 and not stdout and diagnostic in stderr
                clean(directory, pid)
            finally:
                finish(process)

        for cmd, status, diagnostic in [
            (command("normal", digest="0" * 64), 65, "verification failed"),
            (command("normal", digest="not-a-hash"), 65, "64 hexadecimal"),
            (command("normal", index="3"), 65, "selected node number"),
        ]:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=5)
            assert result.returncode == status and not result.stdout and diagnostic in result.stderr
            assert "synthetic-selected" not in result.stderr and not report_file.exists()

        with socket.socket() as occupied:
            occupied.bind(("127.0.0.1", 0))
            occupied.listen()
            result = subprocess.run(command("normal", "--proxy-port", str(occupied.getsockname()[1])),
                                    capture_output=True, text=True, timeout=5)
            assert result.returncode == 69 and not result.stdout and "ports are unavailable" in result.stderr
            assert not report_file.exists()


if __name__ == "__main__":
    if sys.platform != "linux":
        sys.exit("This fixture requires Linux /proc.")
    if len(sys.argv) != 2:
        sys.exit("usage: smoke-linux-runtime.py CLAY_PORTABLE")
    run_checks(str(Path(sys.argv[1]).resolve(strict=True)))
    print("CLAY Linux runtime synthetic checks passed")
