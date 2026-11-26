#!/usr/bin/env python3
"""Exercise desktop controls with synthetic profiles; no real traffic is used."""

import argparse
import hashlib
import os
from pathlib import Path
import runpy
import stat
import subprocess
import sys
import tempfile
import threading
import time
from urllib.error import HTTPError
from urllib.request import ProxyHandler, build_opener

from session import DesktopError, Session, State, default_pac, inspect


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


class TrayHost:
    """Minimal panel on a private session bus; exercises actual SNI and D-Bus menus."""

    XML = """<node><interface name="org.kde.StatusNotifierWatcher">
      <method name="RegisterStatusNotifierItem"><arg type="s" direction="in"/></method>
      <property name="ProtocolVersion" type="i" access="read"/>
      <property name="RegisteredStatusNotifierItems" type="as" access="read"/>
      <property name="IsStatusNotifierHostRegistered" type="b" access="read"/>
      <signal name="StatusNotifierHostRegistered"/><signal name="StatusNotifierHostUnregistered"/>
    </interface></node>"""

    def __init__(self):
        from gi.repository import Gio, GLib
        from tray import HOST_PROPERTY, WATCHER, WATCHER_PATH

        self.GLib, self.Gio = GLib, Gio
        self.interface, self.path, self.property = WATCHER, WATCHER_PATH, HOST_PROPERTY
        self.bus = Gio.DBusConnection.new_for_address_sync(
            Gio.dbus_address_get_for_bus_sync(Gio.BusType.SESSION, None),
            Gio.DBusConnectionFlags.AUTHENTICATION_CLIENT | Gio.DBusConnectionFlags.MESSAGE_BUS_CONNECTION,
            None, None)
        self.present = False
        self.item = None
        self.info = Gio.DBusNodeInfo.new_for_xml(self.XML)
        self.registration = self.bus.register_object(self.path, self.info.interfaces[0], self.register, self.read_property, None)
        assert self.bus.call_sync("org.freedesktop.DBus", "/org/freedesktop/DBus", "org.freedesktop.DBus", "RequestName",
                                  GLib.Variant("(su)", (self.interface, 4)), GLib.VariantType.new("(u)"),
                                  Gio.DBusCallFlags.NONE, 2000, None).unpack() == (1,)

    def register(self, _bus, sender, _path, _interface, _method, parameters, call):
        (path,) = parameters.unpack()
        assert path.startswith("/")
        self.item = (sender, path)
        call.return_value(None)

    def read_property(self, _bus, _sender, _path, _interface, name):
        if name == self.property:
            return self.GLib.Variant("b", self.present)
        if name == "ProtocolVersion":
            return self.GLib.Variant("i", 0)
        if name == "RegisteredStatusNotifierItems":
            return self.GLib.Variant("as", ["".join(self.item)] if self.item is not None else [])
        return None

    def set_present(self, present):
        self.present = present
        signal = "StatusNotifierHostRegistered" if present else "StatusNotifierHostUnregistered"
        self.bus.emit_signal(None, self.path, self.interface, signal, None)

    def invoke(self, until, owner, path, interface, method, parameters):
        result = []
        self.bus.call(owner, path, interface, method, parameters, None, self.Gio.DBusCallFlags.NONE,
                      2500, None, lambda _bus, reply, *_: result.append(reply))
        until(lambda: result)
        return self.bus.call_finish(result[0]).unpack()

    def menu(self, until):
        owner, item = self.item
        get_menu = self.GLib.Variant("(ss)", ("org.kde.StatusNotifierItem", "Menu"))
        (path,) = self.invoke(until, owner, item, "org.freedesktop.DBus.Properties", "Get", get_menu)
        return owner, path

    def layout(self, until):
        owner, path = self.menu(until)
        request = self.GLib.Variant("(iias)", (0, -1, ["label", "enabled", "toggle-state"]))
        _, root = self.invoke(until, owner, path, "com.canonical.dbusmenu", "GetLayout", request)

        def items(branch):
            index, properties, children = branch
            if "label" in properties:
                yield properties["label"], (index, properties)
            for child in children:
                yield from items(child)

        return dict(items(root))

    def click(self, until, label):
        until(lambda: label in self.layout(until))
        item_id, _ = self.layout(until)[label]
        owner, path = self.menu(until)
        click = self.GLib.Variant("(isvu)", (item_id, "clicked", self.GLib.Variant("i", 0), 0))
        self.invoke(until, owner, path, "com.canonical.dbusmenu", "Event", click)

    def close(self):
        self.bus.unregister_object(self.registration)
        self.bus.close_sync(None)


def gsettings(action, key, *values, schema="org.gnome.system.proxy"):
    return subprocess.check_output(["/usr/bin/gsettings", action, schema, key, *values],
                                   text=True, timeout=8).strip()


def fetch_pac(url):
    with build_opener(ProxyHandler({})).open(url, timeout=5) as response:
        assert response.headers.get_content_type() == "application/x-ns-proxy-autoconfig"
        return response.read(16385)


def gnome_recovery_checks(binary):
    from gnome_pac import GnomePac, GnomeSettings, Snapshot

    settings = GnomeSettings.open()
    baseline = settings.read()
    assert baseline.user == (None, None), "Run this fixture with a fresh dconf profile"
    script = default_pac(binary, 18790)
    pac = GnomePac.open()
    try:
        assert stat.S_IMODE(pac.directory.stat().st_mode) == 0o700
        expect_error(lambda: default_pac(binary, 65536), "no confirmed port")
        try:
            second = GnomePac.open()
        except BlockingIOError:
            pass
        else:
            second.close()
            raise AssertionError("two CLAY processes obtained the same recovery lock")
        pac.enable(script)
        assert stat.S_IMODE(pac.journal.stat().st_mode) == 0o600
        assert pac.pending and pac.confirmed()
        url = pac.server.url
        assert gsettings("get", "mode") == "'auto'" and gsettings("get", "autoconfig-url") == repr(url)
        assert fetch_pac(url) == script and b'PROXY 127.0.0.1:18790' in script
        try:
            fetch_pac(url.rsplit("/", 1)[0] + "/other.pac")
        except HTTPError as error:
            assert error.code == 404
        else:
            raise AssertionError("the PAC server returned the script at another path")
        # Simulate app exit before it could restore the user's GSettings values.
    finally:
        pac.close()

    pac = GnomePac.open()
    try:
        assert pac.pending and not pac.serving
        assert pac.release() == "restored" and settings.read() == baseline
        assert not pac.pending
        pac.enable(script)
        external = "https://newer.example.invalid/other.pac"
        gsettings("set", "autoconfig-url", external)
        assert pac.release() == "external"
        assert settings.read() == Snapshot(("auto", external), ("auto", external))
        assert not pac.pending and not pac.serving
        gsettings("reset", "mode")
        gsettings("reset", "autoconfig-url")
        assert settings.read() == baseline
    finally:
        pac.close()
    print("PASS GNOME recovery: private snapshot, exclusive owner, actual dconf readback, reset on restart, external change preserved")


def window_checks(binary, directory, profile, gnome=False):
    import json

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

    host = TrayHost()
    old_url = "https://original.example.invalid/setup.pac"
    old_host = "original.example.invalid"
    if gnome:
        gsettings("set", "mode", "manual")
        gsettings("set", "autoconfig-url", old_url)
        gsettings("set", "host", old_host, schema="org.gnome.system.proxy.http")
    window = window_class(binary, use_system=gnome)
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
        assert window.tray is not None, "Install the Ayatana typelib for GTK tray checks"
        until(lambda: window.tray.registered and host.item is not None)
        assert not window.tray.available
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
        if gnome:
            assert gsettings("get", "mode") == "'manual'"
            assert gsettings("get", "autoconfig-url") == repr(old_url)

        host.set_present(True)
        until(lambda: window.tray.available)
        window.close()
        until(lambda: not window.get_visible())
        assert not destroyed.is_set() and Path(f"/proc/{pid}").exists()

        layout = host.layout(until)
        assert "Global · Node 2" in layout and "Open CLAY" in layout
        assert layout["Node 2"][1]["toggle-state"] == 1 and layout["Global"][1]["toggle-state"] == 1
        assert not any("private-label" in title or "127.0.0.1" in title for title in layout)
        if gnome:
            host.click(until, "Apply to GNOME")
            until(lambda: not window.busy and window.pac.confirmed())
            url = window.pac.server.url
            assert b'PROXY 127.0.0.1:' + str(proxy).encode() in fetch_pac(url)
            assert gsettings("get", "mode") == "'auto'" and gsettings("get", "autoconfig-url") == repr(url)
            host.click(until, "Restore GNOME proxy")
            until(lambda: not window.busy and not window.pac.pending)
            assert window.session.state == State("global", 2, proxy) and Path(f"/proc/{pid}").exists()
            assert gsettings("get", "mode") == "'manual'" and gsettings("get", "autoconfig-url") == repr(old_url)
            host.click(until, "Apply to GNOME")
            until(lambda: not window.busy and window.pac.confirmed())
            previous_pac, url = url, window.pac.server.url
            assert previous_pac != url and b'PROXY 127.0.0.1:' + str(proxy).encode() in fetch_pac(url)
        host.click(until, "Node 1")
        until(lambda: not window.busy and window.nodes.get_active_id() == "1")
        assert "Node 1" in window.status.get_text() and window.address.get_text()
        host.click(until, "Rule")
        until(lambda: not window.busy and window.session.state is None)
        assert not window.address.get_text() and not window.set_mode.get_sensitive()
        layout = host.layout(until)
        assert "Status unconfirmed" in layout
        host.click(until, "Refresh status")
        until(lambda: not window.busy and window.session.state is not None)
        assert window.modes.get_active_id() == "global" and window.address.get_text()
        host.click(until, "Direct")
        until(lambda: not window.busy and window.modes.get_active_id() == "direct")
        assert "Direct mode" in window.status.get_text()
        if gnome:
            assert window.pac.confirmed() and gsettings("get", "autoconfig-url") == repr(url)

        host.click(until, "Open CLAY")
        until(window.get_visible)
        window.close()
        until(lambda: not window.get_visible())
        host.set_present(False)
        until(lambda: not window.tray.available and window.get_visible())
        assert window.session.state == State("direct", 1, proxy)
        host.set_present(True)
        until(lambda: window.tray.available)
        window.close()
        until(lambda: not window.get_visible())
        if gnome:
            # An external change still points to the CLAY listener. Stop must
            # leave both the settings and current process alone until resolved.
            gsettings("set", "mode", "manual")
            host.click(until, "Stop proxy")
            until(lambda: not window.busy and window.get_visible() and "need recovery" in window.system_status.get_text())
            assert window.get_visible() and window.pac.pending and Path(f"/proc/{pid}").exists()
            assert gsettings("get", "mode") == "'manual'" and gsettings("get", "autoconfig-url") == repr(url)
            assert fetch_pac(url)
            gsettings("set", "autoconfig-url", old_url)
        host.click(until, "Stop proxy")
        until(lambda: window.session.process is None and not window.busy)
        assert not Path(directory_name).exists() and not Path(f"/proc/{pid}").exists()
        assert not destroyed.is_set()

        host.click(until, "Open CLAY")
        until(window.get_visible)
        if gnome:
            from subscriptions import Manager, Store

            fixture = Manager(binary, Store(), lambda *_: bytearray(PROFILE.encode("utf-8")))
            entry = fixture.add("Saved fixture", "https://empty.example.invalid/fixture", threading.Event())
            click(window.subscriptions)
            dialog = window.subscription_dialog
            until(lambda: not dialog.busy)
            assert dialog.saved.get_active_id() == entry.id.hex and dialog.use.get_sensitive()
            assert not dialog.url.get_visibility() and "https://" not in dialog.saved.get_active_text()
            assert not window.start.get_sensitive()
            dialog.use.clicked()
            until(lambda: window.subscription_dialog is None)
            assert window.selected_subscription[0] == entry and window.source_label.get_text() == "Saved subscription"
            profile.write_text("invalid local profile", encoding="utf-8")
        # The synthetic core only accepts this startup pair, regardless of
        # what route we selected in the previous session. Require a new report.
        window.nodes.set_active_id("2")
        window.modes.set_active_id("global")
        report.unlink()
        previous_pid = pid
        click(window.system if gnome else window.start)
        assert window.session.state is not None, window.status.get_text()
        directory_name, pid, proxy, _ = json.loads(report.read_text(encoding="utf-8"))
        assert pid != previous_pid and Path(f"/proc/{pid}").exists()
        if gnome:
            assert window.pac.confirmed() and gsettings("get", "mode") == "'auto'", window.system_status.get_text()
            assert not window.subscriptions.get_sensitive()
            host.click(until, "Node 1")
            until(lambda: not window.busy and window.session.state == State("global", 1, proxy))
            host.click(until, "Direct")
            until(lambda: not window.busy and window.session.state == State("direct", 1, proxy))
        window.close()
        until(lambda: not window.get_visible())
        host.click(until, "Quit CLAY")
        until(destroyed.is_set)
        assert not Path(directory_name).exists() and not Path(f"/proc/{pid}").exists()
        assert window.session.process is None
        if gnome:
            assert gsettings("get", "mode") == "'manual'" and gsettings("get", "autoconfig-url") == repr(old_url)
            assert gsettings("get", "host", schema="org.gnome.system.proxy.http") == repr(old_host)
    finally:
        if not destroyed.is_set():
            if gnome:
                gsettings("set", "autoconfig-url", old_url)
            window.request_quit()
            until(destroyed.is_set)
        host.close()
    print("PASS GTK and D-Bus tray: background session, node/mode readback, host loss, stop and quit cleanup")
    if gnome:
        print("PASS GTK GNOME PAC and encrypted subscription: manual path, tray routing, recovery, file-free cached start and quit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("cli", type=Path)
    parser.add_argument("--adapter-only", action="store_true")
    parser.add_argument("--gnome-fixture", action="store_true")
    options = parser.parse_args()
    if options.gnome_fixture:
        fixture = Path(os.environ.get("CLAY_GNOME_FIXTURE", ""))
        assert fixture.is_absolute() and fixture.is_dir() and stat.S_IMODE(fixture.stat().st_mode) == 0o700
        assert os.environ.get("GSETTINGS_BACKEND") == "dconf" and os.environ.get("DBUS_SESSION_BUS_ADDRESS")
        assert os.environ.get("DCONF_PROFILE") == str(fixture / "dconf-profile")
        assert Path.home() == fixture / "home"
        for suffix in ("config", "state", "runtime", "data"):
            assert os.environ.get(f"XDG_{suffix.upper()}_HOME" if suffix != "runtime" else "XDG_RUNTIME_DIR") == str(fixture / suffix)
    binary = options.cli.resolve(strict=True)
    with tempfile.TemporaryDirectory(prefix="clay-desktop-check-") as scratch:
        directory = Path(scratch)
        profile = directory / "本地 profile.txt"
        profile.write_text(PROFILE, encoding="utf-8")
        adapter_checks(binary, directory, profile)
        if not options.adapter_only:
            if options.gnome_fixture:
                gnome_recovery_checks(binary)
            window_checks(binary, directory, profile, gnome=options.gnome_fixture)


if __name__ == "__main__":
    main()
