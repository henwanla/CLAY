#!/usr/bin/env python3
"""GTK 3 preview for the Linux CLAY runtime."""

import argparse
from pathlib import Path
import signal
import threading
import time

import gi

gi.require_version("Gtk", "3.0")
gi.require_version("Gdk", "3.0")
from gi.repository import Gdk, GLib, Gtk, Pango

from desktop_pac import ReleaseError
from gnome_pac import GnomePac
from kde_pac import KdePac, plasma6_session
from session import (DesktopError, EngineInputError, ENGINE_SHA256, MODES, OFFICIAL_ENGINE_SHA256, Session,
                     default_pac, inspect, preview_rules, recognized_engine)
from subscription_dialog import SubscriptionDialog
from subscriptions import Manager, Store, wipe
from tray import create_tray


class Window(Gtk.Window):
    __gtype_name__ = "ClayDesktopWindow"

    def __init__(self, binary, *, use_system=True):
        super().__init__(title="CLAY for Linux")
        self.set_default_size(680, 475)
        self.set_border_width(20)
        self.cancel = threading.Event()
        self.session = Session(binary, self.cancel, before_stop=self.restore_before_stop)
        self.command_lock = threading.Lock()
        self.traffic_pending = False
        self.traffic_generation = 0
        self.previous_traffic = None
        self.pac_notice = None
        self.system_confirmed = False
        self.system_probe_pending = False
        self.system_generation = 0
        self.desktop_name = "Plasma" if plasma6_session() else "GNOME"
        try:
            self.pac = (KdePac.open(binary) if self.desktop_name == "Plasma" else GnomePac.open()) if use_system else None
        except OSError:
            self.pac = None
            self.pac_notice = f"{self.desktop_name} proxy control is unavailable. Manual proxy is still available."
        if use_system and self.desktop_name == "Plasma" and self.pac is None and self.pac_notice is None:
            self.pac_notice = "Manual proxy · Install the Plasma settings helper beside clay-portable for system PAC."
        self.process_seen_ended = None
        self.poll_ticks = 0
        self.preview = None
        self.selected_subscription = None
        self.subscription_dialog = None
        self.rule_dialog = None
        self.engine_verified = False
        self.busy = False
        self.closing = False
        self.destroyed = False
        self.backgrounded = False

        root = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=12)
        self.add(root)
        intro = Gtk.Label(label="Use a local profile or a saved subscription with a verified Mihomo executable.", xalign=0, wrap=True)
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
        self.subscriptions = Gtk.Button(label="Subscriptions…")
        self.subscriptions.connect("clicked", self.open_subscriptions)
        grid.attach(self.subscriptions, 1, 1, 1, 1)
        self.source_label = Gtk.Label(label="Local file", xalign=0, wrap=True)
        grid.attach(self.source_label, 2, 1, 1, 1)
        self.engine = self.chooser("Choose an extracted Mihomo executable")
        self.engine.connect("file-set", self.engine_changed)
        official = Gtk.LinkButton.new_with_label("https://github.com/MetaCubeX/mihomo/releases/tag/v1.19.34",
                                                  "Official v1.19.34")
        row(2, "Mihomo", self.engine, official)
        self.fingerprint = Gtk.Entry(max_length=64, placeholder_text="Expected hash for this executable")
        self.fingerprint.connect("changed", lambda *_: self.sync_controls())
        row(3, "SHA-256", self.fingerprint)
        self.engine_note = Gtk.Label(label="Extract the Linux amd64-compatible build, then select the executable.",
                                     xalign=0, wrap=True)
        grid.attach(self.engine_note, 1, 4, 2, 1)

        self.use_rules = Gtk.CheckButton(label="Use rules file")
        self.use_rules.connect("toggled", lambda *_: self.sync_controls())
        self.rules = self.chooser("Choose a local PAC rules file")
        self.rules.connect("file-set", lambda *_: self.sync_controls())
        self.rule_preview = Gtk.Button(label="Preview rules…")
        self.rule_preview.connect("clicked", self.open_rule_preview)
        grid.attach(self.use_rules, 0, 5, 1, 1)
        grid.attach(self.rules, 1, 5, 1, 1)
        grid.attach(self.rule_preview, 2, 5, 1, 1)

        self.nodes = Gtk.ComboBoxText()
        for cell in self.nodes.get_cells():
            cell.set_property("ellipsize", Pango.EllipsizeMode.END)
            cell.set_property("max-width-chars", 40)
        self.set_node = Gtk.Button(label="Apply node")
        self.set_node.connect("clicked", self.change_node)
        row(6, "Node", self.nodes, self.set_node)
        self.modes = Gtk.ComboBoxText()
        for mode in MODES:
            self.modes.append(mode, mode.title())
        self.modes.set_active_id("rule")
        self.set_mode = Gtk.Button(label="Apply mode")
        self.set_mode.connect("clicked", self.change_mode)
        row(7, "Routing mode", self.modes, self.set_mode)

        actions = Gtk.Box(orientation=Gtk.Orientation.HORIZONTAL, spacing=8)
        root.pack_start(actions, False, False, 0)
        self.start = Gtk.Button(label="Start session")
        self.start.connect("clicked", self.start_session)
        self.system = Gtk.Button(label="Connect desktop proxy")
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
        self.traffic = Gtk.Label(xalign=0, wrap=True)
        root.pack_start(self.traffic, False, False, 0)
        note = Gtk.Label(label="Use the loopback address for manual HTTP or SOCKS5. The desktop PAC applies only "
                               "to apps that use these proxy settings.", xalign=0, wrap=True)
        root.pack_start(note, False, False, 0)
        self.tray_note = Gtk.Label(xalign=0, wrap=True)
        root.pack_start(self.tray_note, False, False, 0)
        self.tray = create_tray(self)
        self.tray_availability_changed(False)
        self.connect("delete-event", self.close_window)
        self.connect("unmap", self.reset_traffic)
        self.connect("window-state-event", self.traffic_window_state)
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
        active = self.busy or self.closing or self.subscription_dialog is not None or self.rule_dialog is not None
        confirmed = not active and self.session.state is not None
        editable = not active and not running
        for widget in (self.profile, self.load, self.subscriptions, self.engine, self.fingerprint, self.use_rules):
            widget.set_sensitive(editable)
        self.fingerprint.set_editable(not self.engine_verified)
        self.rules.set_sensitive(editable and self.use_rules.get_active())
        self.rule_preview.set_sensitive(self.rules.get_sensitive() and bool(self.rules.get_filename()))
        self.nodes.set_sensitive(confirmed or (editable and self.preview is not None))
        self.modes.set_sensitive(confirmed or editable)
        self.set_node.set_sensitive(confirmed)
        self.set_mode.set_sensitive(confirmed)
        self.start.set_sensitive(editable and self.preview is not None and bool(self.engine.get_filename()) and
                                 bool(ENGINE_SHA256.fullmatch(self.fingerprint.get_text().strip())))
        self.stop.set_sensitive(running or self.busy)
        self.refresh.set_sensitive(running and not active)
        if self.tray is not None:
            self.tray.update(running=running, state=self.session.state, busy=active,
                             count=len(self.preview.nodes) if self.preview else 0)
        self.sync_system_controls()

    def sync_system_controls(self):
        pending = self.pac is not None and self.pac.pending
        running = self.session.process is not None
        enabled = self.pac is not None and not self.busy and not self.closing and self.subscription_dialog is None and self.rule_dialog is None and (
            pending or (self.session.state is not None if running else self.start.get_sensitive()))
        name = self.desktop_name
        label = (f"Restore {name} proxy" if pending else f"Apply to {name}" if running else
                 f"Connect {name}" if self.pac is not None else "Desktop proxy unavailable")
        self.system.set_label(label)
        self.system.set_sensitive(enabled)
        if self.tray is not None:
            self.tray.update_system(label, enabled and (running or pending))
        if self.busy and pending:
            return
        if pending:
            recovery = self.pac.recovery_message
            message = (f"{name} PAC configured for apps that follow desktop proxy settings."
                       if self.system_confirmed and self.pac_notice != recovery else recovery)
        else:
            message = self.pac_notice or (f"Manual proxy · {name} settings unchanged" if self.pac is not None
                                          else "Manual proxy · Desktop proxy integration unavailable in this session")
        self.system_status.set_text(message)

    def probe_system(self):
        # KConfig can block on filesystem/helper I/O. Never wait for it on GTK's thread.
        if self.system_probe_pending or not self.pac.serving:
            return
        self.system_probe_pending = True
        generation = self.system_generation

        def check():
            confirmed = False
            try:
                confirmed = self.pac.confirmed()
            except Exception:
                pass
            GLib.idle_add(finish, confirmed)

        def finish(confirmed):
            self.system_probe_pending = False
            if not self.destroyed and not self.busy and generation == self.system_generation:
                self.system_confirmed = confirmed
                self.sync_system_controls()
            return GLib.SOURCE_REMOVE

        threading.Thread(target=check, daemon=True).start()

    def profile_changed(self, *_):
        self.clear_subscription()
        self.preview = None
        self.nodes.remove_all()
        self.status.set_text("Load the selected profile to list its nodes.")
        self.sync_controls()

    def open_subscriptions(self, *_):
        if not self.subscriptions.get_sensitive():
            return
        self.subscription_dialog = SubscriptionDialog(self, Manager(self.session.binary, Store()))
        self.subscription_dialog.connect("destroy", self.subscriptions_closed)
        self.sync_controls()
        self.subscription_dialog.show_all()

    def subscriptions_closed(self, *_):
        self.subscription_dialog = None
        if self.closing:
            self.request_stop()
        elif not self.destroyed:
            self.sync_controls()

    def apply_subscription(self, selection):
        self.clear_subscription()
        self.selected_subscription = selection
        self.source_label.set_text("Saved subscription")
        self.show_preview(selection[1])

    def subscription_removed(self, item):
        if self.selected_subscription is not None and self.selected_subscription[0].id == item:
            self.profile_changed()

    def clear_subscription(self):
        if self.selected_subscription is not None:
            wipe(self.selected_subscription[2])
            self.selected_subscription = None
        self.source_label.set_text("Local file")

    def task(self, message, action, completed, *, system_only=False):
        if self.busy:
            return
        self.busy = True
        self.system_generation += 1
        self.cancel.clear()
        self.reset_traffic()
        if not system_only:
            self.status.set_text(message)
            self.address.set_text("")
        self.sync_controls()
        if system_only:
            self.system_status.set_text(message)

        def run():
            result, message, recovery, invalid_engine = None, None, False, False
            try:
                with self.command_lock:
                    result = action()
            except ReleaseError as error:
                message, recovery = str(error), True
            except EngineInputError as error:
                message, invalid_engine = str(error), True
            except DesktopError as error:
                message = str(error)
            except Exception:
                # Filesystem/process exceptions may contain private paths.
                message = "CLAY could not finish the local operation."
            GLib.idle_add(finish, result, message, recovery, invalid_engine)

        def finish(result, error, recovery, invalid_engine):
            self.busy = False
            if self.destroyed:
                return GLib.SOURCE_REMOVE
            if error is not None:
                if invalid_engine:
                    if self.engine_verified:
                        self.engine_verified = False
                        self.fingerprint.set_text("")
                    self.engine_note.set_text(error)
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

    def engine_changed(self, *_):
        self.engine_verified = False
        self.fingerprint.set_text("")
        path = self.engine.get_filename()
        if not path:
            self.sync_controls()
            return
        self.engine_note.set_text("For another build, enter the SHA-256 obtained from a trusted source.")

        def show(official):
            self.engine_verified = official
            if official:
                self.fingerprint.set_text(OFFICIAL_ENGINE_SHA256)
                self.engine_note.set_text("Official Mihomo v1.19.34 · Linux x64 · Verified")
            self.status.set_text("Choose a node and start when ready." if self.preview else "Load nodes to continue.")

        self.task("Checking the selected executable…", lambda: recognized_engine(path, self.cancel), show)

    def open_rule_preview(self, *_):
        path = self.rules.get_filename()
        if not path or not self.rule_preview.get_sensitive():
            return
        dialog = Gtk.Dialog(title="Rule preview", transient_for=self, modal=True, destroy_with_parent=True)
        dialog.set_default_size(460, -1)
        dialog.add_button("Close", Gtk.ResponseType.CLOSE)
        body = dialog.get_content_area()
        body.set_border_width(12)
        body.set_spacing(8)
        intro = ("Check this file in Rule mode. Global and Direct ignore the file. The system PAC may bypass "
                 "the proxy for local requests. Rule numbers skip comments and blank lines.")
        body.pack_start(Gtk.Label(label=intro, xalign=0, wrap=True), False, False, 0)
        caption = Gtk.Label(label="Domain, IP address or URL (optional)", xalign=0)
        target = Gtk.Entry(max_length=4096)
        caption.set_mnemonic_widget(target)
        body.pack_start(caption, False, False, 0)
        body.pack_start(target, False, False, 0)
        submit = Gtk.Button(label="Check")
        hint = "Leave blank to validate the file. No lookup or connection is made."
        result = Gtk.Label(label=hint, xalign=0, wrap=True)
        body.pack_start(submit, False, False, 0)
        body.pack_start(result, False, False, 0)
        cancelled = threading.Event()

        def closed(*_):
            cancelled.set()
            self.rule_dialog = None
            if not self.destroyed:
                self.sync_controls()

        def finish(message):
            if not cancelled.is_set():
                result.set_text(message)
                submit.set_sensitive(True)
                target.set_sensitive(True)
                target.grab_focus()
            return GLib.SOURCE_REMOVE

        def check(*_):
            if not submit.get_sensitive():
                return
            value = target.get_text()
            submit.set_sensitive(False)
            target.set_sensitive(False)
            result.set_text("Checking…")

            def run():
                try:
                    message = preview_rules(self.session.binary, path, value, cancelled)
                except Exception:
                    message = "Could not check the rules file."
                GLib.idle_add(finish, message)

            threading.Thread(target=run, daemon=True).start()

        target.connect("activate", check)
        target.connect("changed", lambda *_: result.set_text(hint))
        submit.connect("clicked", check)
        dialog.connect("response", lambda *_: dialog.destroy())
        dialog.connect("destroy", closed)
        self.rule_dialog = dialog
        self.sync_controls()
        dialog.show_all()
        target.grab_focus()

    def load_profile(self, *_):
        path = self.profile.get_filename()
        if not path:
            self.status.set_text("Choose a local profile file first.")
            return
        self.clear_subscription()
        self.preview = None
        self.nodes.remove_all()
        self.task("Inspecting profile…", lambda: inspect(self.session.binary, path, self.cancel), self.show_preview)

    def show_preview(self, preview):
        self.preview = preview
        self.nodes.remove_all()
        for index, node in enumerate(preview.nodes, start=1):
            self.nodes.append(str(index), node.caption(index))
        self.nodes.set_active(0)
        message = f"Loaded {len(preview.nodes)} supported nodes."
        if preview.skipped:
            message += f" Skipped {preview.skipped} entries."
        self.status.set_text(message)

    def start_session(self, *_, connect_desktop=False):
        rules = self.rules.get_filename() if self.use_rules.get_active() else None
        if self.preview is None or not self.start.get_sensitive():
            return
        if self.use_rules.get_active() and not rules:
            self.status.set_text("Choose a rules file, or turn off the rules file option.")
            return
        path, preview = self.profile.get_filename(), self.preview
        source = self.selected_subscription[2] if self.selected_subscription is not None else None
        node, mode = int(self.nodes.get_active_id()), self.modes.get_active_id()
        engine, digest = self.engine.get_filename(), self.fingerprint.get_text().strip()
        def start():
            state = self.session.start(path, preview, node, engine, digest, mode, rules, source=source)
            if connect_desktop and not self.cancel.is_set():
                try:
                    self.enable_desktop(state)
                except DesktopError as error:
                    self.pac_notice = str(error)
                except Exception:
                    self.pac_notice = f"{self.desktop_name} PAC could not be configured. The manual proxy is still available."
            return state

        self.task("Starting Mihomo and checking its controller…", start, self.display_state)

    def enable_desktop(self, state):
        script = default_pac(self.session.binary, state.port, self.cancel)
        child = self.session.process
        if self.cancel.is_set() or child is None or child.poll() is not None:
            raise DesktopError("The local session is no longer ready.")
        self.pac.enable(script)
        self.system_confirmed = True
        self.pac_notice = None

    def restore_desktop(self):
        result = self.pac.release()
        self.system_confirmed = False
        self.pac_notice = {"restored": f"Original {self.desktop_name} proxy settings restored.",
                           "external": f"The newer {self.desktop_name} proxy settings were preserved."}.get(result)

    def restore_before_stop(self):
        if self.pac is not None and self.pac.serving:
            self.restore_desktop()

    def toggle_system(self, *_):
        if self.busy or self.pac is None or self.subscription_dialog is not None:
            return
        if self.pac.pending:
            self.task(f"Checking and restoring {self.desktop_name} settings…", self.restore_desktop, lambda _: None, system_only=True)
        elif self.session.process is None and self.start.get_sensitive():
            self.start_session(connect_desktop=True)
        elif (confirmed := self.session.state) is not None and self.system.get_sensitive():
            self.task(f"Configuring {self.desktop_name} PAC…", lambda: self.enable_desktop(confirmed), lambda _: None, system_only=True)

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

    def reset_traffic(self, *_):
        self.traffic_generation += 1
        self.previous_traffic = None
        self.traffic.set_text("")

    def traffic_window_state(self, _, event):
        if event.changed_mask & Gdk.WindowState.ICONIFIED:
            self.reset_traffic()
        return False

    def traffic_visible(self):
        surface = self.get_window()
        return self.get_mapped() and surface is not None and not (surface.get_state() & Gdk.WindowState.ICONIFIED)

    def poll_traffic(self, child):
        if (child is None or self.session.state is None or self.closing or
                self.traffic_pending or not self.traffic_visible()):
            return
        generation = self.traffic_generation
        self.traffic_pending = True

        def read():
            counts, error, recovery = None, None, False
            try:
                with self.command_lock:
                    # An explicit operation can take priority if this worker hasn't started the read.
                    if generation == self.traffic_generation and self.session.process is child:
                        counts = self.session.sample_traffic()
            except ReleaseError as failure:
                error, recovery = str(failure), True
            except Exception:
                error = "The local session stopped responding. Refresh or start it again."
            GLib.idle_add(finish, counts, time.monotonic(), error, recovery)

        def finish(counts, now, error, recovery):
            self.traffic_pending = False
            if self.destroyed or self.busy:
                return GLib.SOURCE_REMOVE
            if error is not None and self.session.state is None:
                # The bridge may have closed a failed session or left its PAC up for recovery.
                self.reset_traffic()
                self.address.set_text("")
                self.status.set_text(error)
                if recovery:
                    self.pac_notice = error
                    self.show_window()
                self.sync_controls()
            elif (self.session.process is child and self.session.state is not None and
                  generation == self.traffic_generation and self.traffic_visible()):
                self.display_traffic(counts, now)
            return GLib.SOURCE_REMOVE

        threading.Thread(target=read, daemon=True).start()

    def display_traffic(self, counts, now):
        previous = self.previous_traffic
        self.previous_traffic = (counts, now) if counts is not None else None
        if counts is None:
            self.traffic.set_text("Traffic counters are temporarily unavailable.")
            return
        up, down = counts
        message = f"Session total · Up {up:,} B · Down {down:,} B"
        if previous is not None:
            (old_up, old_down), then = previous
            seconds = now - then
            if seconds > 0 and up >= old_up and down >= old_down:
                message += f"\nRate · Up {(up - old_up) / seconds:,.0f} B/s · Down {(down - old_down) / seconds:,.0f} B/s"
        self.traffic.set_text(message)

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
        elif not self.busy:
            self.poll_ticks += 1
            if self.poll_ticks % 5 == 0:
                if self.pac is not None and self.pac.pending:
                    self.probe_system()
                self.poll_traffic(child)
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
        if self.subscription_dialog is not None:
            self.subscription_dialog.request_close()
            return
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
        self.clear_subscription()
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
