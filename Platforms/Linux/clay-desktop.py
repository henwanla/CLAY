#!/usr/bin/env python3
"""GTK 3 preview for the Linux CLAY runtime."""

import argparse
from pathlib import Path
import signal
import threading

import gi

gi.require_version("Gtk", "3.0")
from gi.repository import GLib, Gtk

from gnome_pac import GnomePac, RECOVERY_NEEDED, ReleaseError
from session import DesktopError, MODES, Session, default_pac, inspect
from tray import create_tray


class Window(Gtk.Window):
    __gtype_name__ = "ClayDesktopWindow"

    def __init__(self, binary, *, use_system=True):
        super().__init__(title="CLAY for Linux")
        self.set_default_size(680, 475)
        self.set_border_width(20)
        self.cancel = threading.Event()
        self.session = Session(binary, self.cancel, before_stop=self.restore_before_stop)
        self.pac_notice = None
        try:
            self.pac = GnomePac.open() if use_system else None
        except OSError:
            self.pac = None
            self.pac_notice = "GNOME proxy control is unavailable. Manual proxy is still available."
        self.process_seen_ended = None
        self.poll_ticks = 0
        self.preview = None
        self.busy = False
        self.closing = False
        self.destroyed = False
        self.backgrounded = False

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.add(root)
        intro = Gtk.Label(label="Use a local profile with a verified Mihomo executable.", xalign=0)
        root.pack_start(intro, False, False, 0)
        grid = Gtk.Grid(column_spacing=12, row_spacing=8)
        root.pack_start(grid, False, False, 0)

        def row(index, label, widget, button=None):
            grid.attach(Gtk.Label(label=label, xalign=0), 0, index, 1, 1)
            widget.set_hexpand(True)
            grid.attach(widget, 1, index, 1, 1)
            if button:
                grid.attach(button, 2, index, 1, 1)

        self.profile = self.chooser("Choose a local profile")
        self.profile.connect("file-set", self.profile_changed)
        self.load = Gtk.Button(label="Load nodes")
        self.load.connect("clicked", self.load_profile)
        row(0, "Profile", self.profile, self.load)
        self.engine = self.chooser("Choose an extracted Mihomo executable")
        row(1, "Mihomo", self.engine)
        self.fingerprint = Gtk.Entry(max_length=64, placeholder_text="Expected hash for this executable")
        row(2, "SHA-256", self.fingerprint)

        self.use_rules = Gtk.CheckButton(label="Use rules file")
        self.use_rules.connect("toggled", lambda *_: self.sync_controls())
        self.rules = self.chooser("Choose a local PAC rules file")
        grid.attach(self.use_rules, 0, 3, 1, 1)
        grid.attach(self.rules, 1, 3, 1, 1)

        self.nodes = Gtk.ComboBoxText()
        self.set_node = Gtk.Button(label="Apply node")
        self.set_node.connect("clicked", self.change_node)
        row(4, "Node", self.nodes, self.set_node)
        self.modes = Gtk.ComboBoxText()
        for mode in MODES:
            self.modes.append(mode, mode.title())
        self.modes.set_active_id("rule")
        self.set_mode = Gtk.Button(label="Apply mode")
        self.set_mode.connect("clicked", self.change_mode)
        row(5, "Routing mode", self.modes, self.set_mode)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        root.pack_start(actions, False, False, 0)
        self.start = Gtk.Button(label="Start session")
        self.start.connect("clicked", self.start_session)
        self.system = Gtk.Button(label="Connect GNOME")
        self.system.connect("clicked", self.toggle_system)
        self.stop = Gtk.Button(label="Stop")
        self.stop.connect("clicked", lambda *_: self.request_stop())
        self.refresh = Gtk.Button(label="Refresh status")
        self.refresh.connect("clicked", self.refresh_session)
        quit_button = Gtk.Button(label="Quit CLAY")
        quit_button.connect("clicked", lambda *_: self.request_quit())
        for button in (self.start, self.system, self.stop, self.refresh):
            actions.pack_start(button, False, False, 0)
        actions.pack_end(quit_button, False, False, 0)

        self.status = Gtk.Label(label="Stopped. Load a profile to get started.", xalign=0, wrap=True)
        root.pack_start(self.status, False, False, 0)
        self.system_status = Gtk.Label(xalign=0, wrap=True)
        root.pack_start(self.system_status, False, False, 0)
        self.address = Gtk.Entry(editable=False, can_focus=True, placeholder_text="No confirmed local proxy address")
        root.pack_start(self.address, False, False, 0)
        note = Gtk.Label(label="Use the loopback address for manual HTTP or SOCKS5. Connect GNOME applies "
                               "a script for apps that follow the GNOME proxy settings.", xalign=0, wrap=True)
        root.pack_start(note, False, False, 0)
        self.tray_note = Gtk.Label(xalign=0, wrap=True)
        root.pack_start(self.tray_note, False, False, 0)
        self.tray = create_tray(self)
        self.tray_availability_changed(False)
        self.connect("delete-event", self.close_window)
        self.poll_source = GLib.timeout_add(400, self.watch_child)
        self.connect("destroy", self.window_destroyed)
        self.sync_controls()
        if self.pac is not None and self.pac.pending:
            self.toggle_system()

    @staticmethod
    def chooser(title):
        button = Gtk.FileChooserButton(title=title, action=Gtk.FileChooserAction.OPEN)
        button.set_local_only(True)
        return button

    def sync_controls(self):
        running = self.session.process is not None
        active = self.busy or self.closing
        confirmed = not active and self.session.state is not None
        editable = not active and not running
        for widget in (self.profile, self.load, self.engine, self.fingerprint, self.use_rules):
            widget.set_sensitive(editable)
        self.rules.set_sensitive(editable and self.use_rules.get_active())
        self.nodes.set_sensitive(confirmed or (editable and self.preview is not None))
        self.modes.set_sensitive(confirmed or editable)
        self.set_node.set_sensitive(confirmed)
        self.set_mode.set_sensitive(confirmed)
        self.start.set_sensitive(editable and self.preview is not None)
        self.stop.set_sensitive(running or self.busy)
        self.refresh.set_sensitive(running and not active)
        if self.tray is not None:
            self.tray.update(running=running, state=self.session.state, busy=active,
                             count=len(self.preview.nodes) if self.preview else 0)
        self.sync_system_controls()

    def sync_system_controls(self):
        pending = self.pac is not None and self.pac.pending
        running = self.session.process is not None
        enabled = self.pac is not None and not self.busy and not self.closing and (
            pending or (self.session.state is not None if running else self.start.get_sensitive()))
        label = "Restore GNOME proxy" if pending else "Apply to GNOME" if running else "Connect GNOME"
        self.system.set_label(label)
        self.system.set_sensitive(enabled)
        if self.tray is not None:
            self.tray.update_system(label, enabled and (running or pending))
        if self.busy and pending:
            return  # Keep the prior system indicator while the worker is active.
        configured = False
        if pending:
            try:
                configured = self.pac.confirmed()
            except Exception:
                pass
        if configured and self.pac_notice != RECOVERY_NEEDED:
            message = "GNOME PAC configured for apps that follow desktop proxy settings."
        elif pending:
            message = RECOVERY_NEEDED
        else:
            message = self.pac_notice or ("Manual proxy · GNOME settings unchanged" if self.pac is not None
                                          else "Manual proxy · GNOME integration unavailable in this session")
        self.system_status.set_text(message)

    def profile_changed(self, *_):
        self.preview = None
        self.nodes.remove_all()
        self.status.set_text("Load the selected profile to list its nodes.")
        self.sync_controls()

    def task(self, message, action, completed, *, system_only=False):
        if self.busy:
            return
        self.busy = True
        self.cancel.clear()
        if not system_only:
            self.status.set_text(message)
            self.address.set_text("")
        self.sync_controls()
        if system_only:
            self.system_status.set_text(message)

        def run():
            result, message, recovery = None, None, False
            try:
                result = action()
            except ReleaseError as error:
                message, recovery = str(error), True
            except DesktopError as error:
                message = str(error)
            except Exception:
                # Filesystem/process exceptions may contain private paths.
                message = "CLAY could not finish the local operation."
            GLib.idle_add(finish, result, message, recovery)

        def finish(result, error, recovery):
            self.busy = False
            if error is not None:
                if system_only or recovery:
                    self.pac_notice = error
                if not system_only:
                    self.status.set_text("The session could not stop safely." if recovery else error)
                if self.closing or self.session.process is None or recovery:
                    self.show_window()
                if not self.cancel.is_set():
                    self.closing = False
            elif not self.cancel.is_set():
                completed(result)
            if self.destroyed:
                return GLib.SOURCE_REMOVE
            self.sync_controls()
            if self.cancel.is_set():
                self.request_stop()
            return GLib.SOURCE_REMOVE

        threading.Thread(target=run).start()

    def load_profile(self, *_):
        path = self.profile.get_filename()
        if not path:
            self.status.set_text("Choose a local profile file first.")
            return
        self.preview = None
        self.nodes.remove_all()

        def loaded(preview):
            self.preview = preview
            for index, node in enumerate(preview.nodes, start=1):
                self.nodes.append(str(index), f"{index} · {node}")
            self.nodes.set_active(0)
            message = f"Loaded {len(preview.nodes)} supported nodes."
            if preview.skipped:
                message += f" Skipped {preview.skipped} entries."
            self.status.set_text(message)

        self.task("Inspecting profile…", lambda: inspect(self.session.binary, path, self.cancel), loaded)

    def start_session(self, *_, connect_gnome=False):
        rules = self.rules.get_filename() if self.use_rules.get_active() else None
        if self.preview is None or self.busy:
            return
        if self.use_rules.get_active() and not rules:
            self.status.set_text("Choose a rules file, or turn off the rules file option.")
            return
        path, preview = self.profile.get_filename(), self.preview
        node, mode = int(self.nodes.get_active_id()), self.modes.get_active_id()
        engine, digest = self.engine.get_filename(), self.fingerprint.get_text().strip()
        def start():
            state = self.session.start(path, preview, node, engine, digest, mode, rules)
            if connect_gnome and not self.cancel.is_set():
                try:
                    self.enable_gnome(state)
                except DesktopError as error:
                    self.pac_notice = str(error)
                except Exception:
                    self.pac_notice = "GNOME PAC could not be configured. The manual proxy is still available."
            return state

        self.task("Starting Mihomo and checking its controller…", start, self.display_state)

    def enable_gnome(self, state):
        script = default_pac(self.session.binary, state.port, self.cancel)
        child = self.session.process
        if self.cancel.is_set() or child is None or child.poll() is not None:
            raise DesktopError("The local session is no longer ready.")
        self.pac.enable(script)
        self.pac_notice = None

    def restore_gnome(self):
        result = self.pac.release()
        self.pac_notice = {"restored": "Original GNOME proxy settings restored.",
                           "external": "The newer GNOME proxy settings were preserved."}.get(result)

    def restore_before_stop(self):
        if self.pac is not None and self.pac.serving:
            self.restore_gnome()

    def toggle_system(self, *_):
        if self.busy or self.pac is None:
            return
        if self.pac.pending:
            self.task("Checking and restoring GNOME settings…", self.restore_gnome, lambda _: None, system_only=True)
        elif self.session.process is None and self.start.get_sensitive():
            self.start_session(connect_gnome=True)
        elif (confirmed := self.session.state) is not None and self.system.get_sensitive():
            self.task("Configuring GNOME PAC…", lambda: self.enable_gnome(confirmed), lambda _: None, system_only=True)

    def change_node(self, *_):
        if self.nodes.get_active_id() is not None:
            self.apply_node(int(self.nodes.get_active_id()))

    def apply_node(self, node):
        if self.set_node.get_sensitive():
            self.task("Checking the selected node…", lambda: self.session.change(node=node), self.display_state)

    def change_mode(self, *_):
        self.apply_mode(self.modes.get_active_id())

    def apply_mode(self, mode):
        if self.set_mode.get_sensitive():
            self.task("Checking the routing mode…", lambda: self.session.change(mode=mode), self.display_state)

    def refresh_session(self, *_):
        if self.refresh.get_sensitive():
            self.task("Checking the session…", self.session.refresh, self.display_state)

    def display_state(self, state):
        self.nodes.set_active_id(str(state.node))
        self.modes.set_active_id(state.mode)
        self.status.set_text(f"Local proxy ready · {state.mode.title()} mode · Node {state.node}")
        self.address.set_text(f"127.0.0.1:{state.port}")

    def watch_child(self):
        child = self.session.process
        if not self.busy and child is not None and child is not self.process_seen_ended and child.poll() is not None:
            self.process_seen_ended = child
            def ended(_):
                self.status.set_text("The local session ended. Start it again to reconnect.")
                self.show_window()

            self.task("Closing the local session…", self.session.stop, ended)
        elif not self.busy and self.pac is not None and self.pac.pending:
            self.poll_ticks += 1
            if self.poll_ticks % 5 == 0:
                self.sync_system_controls()
        return GLib.SOURCE_CONTINUE

    def request_stop(self):
        if self.busy:
            self.cancel.set()
            self.status.set_text("Stopping…")
            return
        self.cancel.clear()

        def stopped(_=None):
            self.status.set_text("Stopped.")
            if self.closing:
                self.destroy()

        if self.session.process is not None:
            self.task("Stopping…", self.session.stop, stopped)
        else:
            stopped()

    def close_window(self, *_):
        child = self.session.process
        if not self.closing and self.tray is not None and self.tray.available and child is not None and child.poll() is None:
            self.backgrounded = True
            self.hide()
        else:
            self.request_quit()
        return True

    def request_quit(self):
        self.closing = True
        self.request_stop()

    def show_window(self):
        self.backgrounded = False
        self.present()

    def tray_availability_changed(self, available):
        self.tray_note.set_text("While the proxy is running, closing this window keeps it in the tray. Use Quit CLAY to exit."
                                if available else "No active tray. Closing this window stops the proxy.")
        if not available and self.backgrounded:
            self.show_window()

    def window_destroyed(self, *_):
        self.destroyed = True
        GLib.source_remove(self.poll_source)
        if self.tray is not None:
            self.tray.close()
        if self.pac is not None:
            self.pac.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--cli", required=True, type=Path, help="path to the built clay-portable executable")
    options = parser.parse_args()
    window = Window(options.cli.resolve())
    signal_sources = []

    def stop_on_signal():
        window.request_quit()
        return GLib.SOURCE_CONTINUE

    for kind in (signal.SIGINT, signal.SIGTERM):
        signal_sources.append(GLib.unix_signal_add(GLib.PRIORITY_DEFAULT, kind, stop_on_signal))
    window.connect("destroy", lambda *_: Gtk.main_quit())
    window.show_all()
    try:
        Gtk.main()
    finally:
        for source in signal_sources:
            GLib.source_remove(source)
        if window.session.process is not None:
            window.session.stop(interrupt=True)


if __name__ == "__main__":
    main()
