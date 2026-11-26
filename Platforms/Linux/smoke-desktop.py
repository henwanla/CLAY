#!/usr/bin/env python3
"""Exercise desktop controls with synthetic profiles; no real traffic is used."""

import argparse
import hashlib
from pathlib import Path
import runpy
import sys
import tempfile
import threading
import time

from session import DesktopError, Session, State, inspect


ADAPTER_CLI = '''
import os
from pathlib import Path
import stat
import sys
mode = sys.argv[sys.argv.index("--mode") + 1]
node = int(sys.argv[3])
assert sys.argv[1] == "mihomo-run" and "--interactive" in sys.argv and "--all-nodes" in sys.argv
profile = Path(sys.argv[2])
assert stat.S_IMODE(profile.parent.stat().st_mode) == 0o700
assert stat.S_IMODE(profile.stat().st_mode) == 0o600
assert "synthetic-selected" in profile.read_text()
assert "HTTP_PROXY" not in os.environ
if mode == "rule":
    print("mihomo=ready proxy=192.0.2.1:1234 controller=127.0.0.1:1235", flush=True)
elif mode == "direct":
    print("mihomo=ready proxy=127.0.0.1:70000 controller=127.0.0.1:1235", flush=True)
else:
    print("mihomo=ready proxy=127.0.0.1:1234 controller=127.0.0.1:1235", flush=True)
for line in sys.stdin:
    command, _, value = line.strip().partition(" ")
    if command == "status":
        print(f"mode={mode} node={node}", flush=True)
    elif command == "node":
        node = int(value)
        print(f"node={node}", flush=True)
    elif command == "mode":
        if value != "rule":
            mode = value
        # Simulate a CLI that claims success before confirming the update.
        print(f"mode={value}", flush=True)
    elif command == "quit":
        break
'''


PROFILE = ("ss://aes-128-gcm:unused@private-label.example.test:9001#synthetic-private-name\n"
           "trojan://synthetic-selected@127.0.0.1:9002#second\n"
           "https://never-fetch.example.test/private\n")


def expect_error(action, text):
    try:
        action()
    except DesktopError as error:
        assert text in str(error), error
    else:
        raise AssertionError("the local adapter accepted an unverified result")


def adapter_checks(binary, directory, profile):
    preview = inspect(binary, profile)
    assert preview.nodes == ("ss/tcp/aead", "trojan/tcp/tls")
    assert preview.skipped == 1
    fixture = directory / "synthetic-cli"
    fixture.write_text(f"#!{sys.executable}\n" + ADAPTER_CLI, encoding="utf-8")
    fixture.chmod(0o700)
    session = Session(fixture, threading.Event())

    def launch(mode="global"):
        return session.start(profile, preview, 2, fixture, "0" * 64, mode)

    profile.write_text(PROFILE.replace("#second", "#edited"), encoding="utf-8")
    expect_error(launch, "profile file changed")
    assert session.process is None
    profile.write_text(PROFILE, encoding="utf-8")
    for mode in ("rule", "direct"):
        expect_error(lambda: launch(mode), "two loopback listeners")
        assert session.process is None
    try:
        assert launch() == State("global", 2, 1234)
        assert session.change(node=1) == State("global", 1, 1234)
        expect_error(lambda: session.change(mode="rule"), "did not confirm")
        assert session.state is None
        assert session.refresh() == State("global", 1, 1234)
        assert session.change(mode="direct") == State("direct", 1, 1234)
        child = session.process
    finally:
        session.stop()
    assert child.returncode == 0 and child.stdin.closed and child.stdout.closed
    print("PASS desktop adapter rejects stale settings, invalid listeners and unconfirmed changes")


def window_checks(binary, directory, profile):
    import json
    import signal

    window_class = runpy.run_path(str(Path(__file__).with_name("clay-desktop.py")))["Window"]
    from gi.repository import GLib

    root = Path(__file__).resolve().parents[2]
    template = runpy.run_path(str(root / "scripts" / "smoke-linux-runtime.py"))["ENGINE"]
    engine, report, rules = (directory / name for name in ("mihomo", "engine-report", "rules.txt"))
    engine.write_text(template.replace("import json\n", f"MODE = 'control'\nREPORT = {str(report)!r}\nimport json\n", 1),
                      encoding="utf-8")
    engine.chmod(0o700)
    fingerprint = hashlib.sha256(engine.read_bytes()).hexdigest()
    rules.write_text("DOMAIN-SUFFIX,example.test,DIRECT\n", encoding="utf-8")

    window = window_class(binary)
    destroyed = threading.Event()
    window.connect("destroy", lambda *_: destroyed.set())
    window.show_all()

    def until(condition, seconds=24):
        context = GLib.MainContext.default()
        end = time.monotonic() + seconds
        while time.monotonic() < end:
            while context.pending():
                context.iteration(False)
            if condition():
                return
            time.sleep(0.02)
        raise AssertionError("GTK window did not reach its expected state")

    def click(button):
        assert button.get_sensitive()
        button.clicked()
        until(lambda: not window.busy)

    try:
        assert not window.start.get_sensitive()
        assert window.profile.set_filename(str(profile))
        until(lambda: window.profile.get_filename() == str(profile))
        click(window.load)
        assert window.nodes.get_active_id() == "1" and "ss/tcp/aead" in window.nodes.get_active_text()
        assert "private-label" not in window.nodes.get_active_text()
        assert "Skipped 1" in window.status.get_text()
        window.nodes.set_active_id("2")
        assert window.engine.set_filename(str(engine))
        window.use_rules.set_active(True)
        assert window.rules.set_filename(str(rules))
        until(lambda: window.engine.get_filename() == str(engine) and window.rules.get_filename() == str(rules))
        window.modes.set_active_id("global")

        window.fingerprint.set_text("0" * 64)
        click(window.start)
        assert not window.address.get_text() and not report.exists()
        assert window.session.process is None

        window.fingerprint.set_text(fingerprint)
        click(window.start)
        directory_name, pid, proxy, _ = json.loads(report.read_text(encoding="utf-8"))
        assert window.address.get_text() == f"127.0.0.1:{proxy}"
        assert window.nodes.get_active_id() == "2" and "Global mode" in window.status.get_text()

        window.nodes.set_active_id("1")
        click(window.set_node)
        assert "Node 1" in window.status.get_text() and window.address.get_text()
        window.modes.set_active_id("rule")
        click(window.set_mode)
        assert not window.address.get_text() and not window.set_mode.get_sensitive()
        click(window.refresh)
        assert window.modes.get_active_id() == "global" and window.address.get_text()
        window.modes.set_active_id("direct")
        click(window.set_mode)
        assert "Direct mode" in window.status.get_text()

        # Dismissing the actual window drives its delete-event cleanup handler.
        window.close()
        until(destroyed.is_set)
        assert not Path(directory_name).exists() and not Path(f"/proc/{pid}").exists()
        assert window.session.process is None
    finally:
        if not destroyed.is_set():
            window.close_window()
            until(destroyed.is_set)
    print("PASS GTK profile loading, engine verification, controller readback and close cleanup")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", type=Path)
    parser.add_argument("--adapter-only", action="store_true")
    options = parser.parse_args()
    binary = options.cli.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="clay-desktop-check-") as scratch:
        directory = Path(scratch)
        profile = directory / "本地 profile.txt"
        profile.write_text(PROFILE, encoding="utf-8")
        adapter_checks(binary, directory, profile)
        if not options.adapter_only:
            window_checks(binary, directory, profile)


if __name__ == "__main__":
    main()
