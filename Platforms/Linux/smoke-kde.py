#!/usr/bin/env python3
"""Exercise native KConfig and KDE's libproxy resolver on disposable settings."""

import argparse
import os
from pathlib import Path
import runpy
import stat
import subprocess

from desktop_pac import ReleaseError, Snapshot
from kde_pac import KdePac, KdeSettings
from session import DesktopError, default_pac


def proxy_for(url):
    env = {name: os.environ[name] for name in ("HOME", "XDG_CONFIG_HOME", "XDG_CURRENT_DESKTOP")}
    env["PX_FORCE_CONFIG"] = "config-kde"
    return subprocess.check_output(["/usr/bin/proxy", url], text=True, timeout=8, env=env).strip().split()


def rejects(action, exception):
    try:
        action()
    except exception:
        return
    raise AssertionError("unsafe or stale KDE settings were accepted")


def check(binary, scratch):
    # Outside the isolation preflight this test must not construct a settings adapter.
    file = scratch / "config/kioslaverc"
    inherited = scratch / "defaults/kioslaverc"
    before_file = "[Proxy Settings]\nhttpProxy=http://127.0.0.1:19991\n\n[Other]\nKeep=on\n"
    file.write_text(before_file)
    inherited.write_text("[Proxy Settings]\nProxyType=1\n")
    settings = KdeSettings(binary)
    baseline = Snapshot(("1", ""), (None, None))
    assert settings.read() == baseline, "KConfig did not distinguish inherited and user values"
    old_proxy = "http://127.0.0.1:19991"
    port = 18790
    script = default_pac(binary, port)
    pac = KdePac.open(binary)
    assert pac is not None
    try:
        rejects(lambda: KdePac.open(binary), BlockingIOError)
        pac.enable(script)
        assert pac.confirmed() and stat.S_IMODE(pac.journal.stat().st_mode) == 0o600
        url = pac.server.url
        assert f"http://127.0.0.1:{port}" in proxy_for("https://example.invalid/check"), "KDE resolver bypassed the PAC"
        assert "direct://" in proxy_for("http://127.0.0.1/check"), "KDE PAC did not keep local traffic direct"
        assert old_proxy in file.read_text() and "Keep=on" in file.read_text()
        rejects(lambda: settings.write(baseline, ("0", "")), DesktopError)
    finally:
        pac.close()  # Simulate crash before restoration.

    pac = KdePac.open(binary)
    try:
        assert pac.pending and not pac.serving
        assert pac.release() == "restored" and settings.read() == baseline
        assert "Keep=on" in file.read_text()
        # Restore both explicit and inherited fields, and handle a conflicting
        # mode while another settings editor still references our listener.
        original = ("1", "https://previous.example.invalid/example.pac?fixture=original")
        settings.write(baseline, original)
        pac.enable(script)
        settings.write(settings.read(), ("1", pac.server.url))
        rejects(pac.release, ReleaseError)
        assert pac.serving and pac.pending
        external = ("2", "https://newer.example.invalid/example.pac")
        settings.write(settings.read(), external)
        assert pac.release() == "external" and settings.read() == Snapshot(external, external)
        settings.write(settings.read(), original)
        pac.enable(script)
        assert pac.release() == "restored" and settings.read() == Snapshot(original, original)
        assert not pac.pending and not pac.serving

        unsafe = "[Proxy Settings]\nProxyType=0\n\n[Other]\nProxyType=1\n"
        file.write_text(unsafe)
        rejects(settings.read, DesktopError)
        assert file.read_text() == unsafe
        file.write_text(before_file)
        inherited.write_text("[Proxy Settings][$i]\nProxyType=1\n")
        rejects(lambda: pac.enable(script), DesktopError)
        assert not pac.pending and not pac.serving and file.read_text() == before_file
        inherited.unlink()
    finally:
        pac.close()
    assert url not in file.read_text()
    print("PASS KDE PAC: native KConfig, direct/proxy via libproxy, inherited defaults, stale write, locked settings and crash recovery")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    args = parser.parse_args()
    scratch = Path(os.environ["CLAY_KDE_FIXTURE"])
    assert scratch.is_absolute() and stat.S_IMODE(scratch.stat().st_mode) == 0o700
    assert Path.home() == scratch / "home" and os.environ["XDG_CURRENT_DESKTOP"] == "KDE"
    assert os.environ["KDE_SESSION_VERSION"] == "6"
    for key, folder in (("XDG_CONFIG_HOME", "config"), ("XDG_CONFIG_DIRS", "defaults"), ("XDG_STATE_HOME", "state")):
        assert os.environ[key] == str(scratch / folder)
    binary = args.binary.resolve(strict=True)
    check(binary, scratch)
    fixture = runpy.run_path(str(Path(__file__).with_name("smoke-desktop.py")))
    profile = scratch / "nodes.txt"
    profile.write_text(fixture["PROFILE"])
    fixture["window_checks"](binary, scratch, profile, plasma=True)


if __name__ == "__main__":
    main()
