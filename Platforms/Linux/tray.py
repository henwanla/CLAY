"""Optional Linux tray integration for desktop sessions with a live panel host."""

import gi
from gi.repository import Gio, GLib, Gtk

from session import MODES


WATCHER = "org.kde.StatusNotifierWatcher"
WATCHER_PATH = "/StatusNotifierWatcher"
HOST_PROPERTY = "IsStatusNotifierHostRegistered"
QUICK_NODES = 12


def create_tray(window):
    try:
        gi.require_version("AyatanaAppIndicator3", "0.1")
        from gi.repository import AyatanaAppIndicator3
    except (ImportError, ValueError):
        return None
    return Tray(window, AyatanaAppIndicator3)


class Tray:
    def __init__(self, window, api):
        self.window = window
        self.api = api
        self.available = False
        self.registered = False
        self.closed = False
        self.updating = False
        self.watcher = None
        self.probe = 0
        self.cancellable = Gio.Cancellable()
        self.indicator = api.Indicator.new("clay-linux", "network-offline-symbolic",
                                           api.IndicatorCategory.APPLICATION_STATUS)
        self.registration_handler = self.indicator.connect("connection-changed", self.registration_changed)
        self.menu = Gtk.Menu()
        self.summary = self.item(self.menu, "Stopped")
        self.summary.set_sensitive(False)
        open_item = self.item(self.menu, "Open CLAY", window.show_window)
        self.nodes, self.node_menu = self.submenu("Switch node")
        self.node_items = {}
        self.node_key = None
        self.modes, mode_menu = self.submenu("Routing mode")
        self.mode_items = {mode: self.choice(mode_menu, mode.title(), lambda mode=mode: window.apply_mode(mode))
                           for mode in MODES}
        self.refresh = self.item(self.menu, "Refresh status", window.refresh_session)
        self.system = self.item(self.menu, "Desktop proxy", window.toggle_system)
        self.stop = self.item(self.menu, "Stop proxy", window.request_stop)
        self.menu.append(Gtk.SeparatorMenuItem())
        self.item(self.menu, "Quit CLAY", window.request_quit)
        self.menu.show_all()
        self.indicator.set_title("CLAY")
        self.indicator.set_menu(self.menu)
        self.indicator.set_secondary_activate_target(open_item)
        self.indicator.set_status(api.IndicatorStatus.ACTIVE)
        Gio.DBusProxy.new_for_bus(Gio.BusType.SESSION, Gio.DBusProxyFlags.DO_NOT_AUTO_START, None,
                                 WATCHER, WATCHER_PATH, WATCHER, self.cancellable, self.watcher_ready)

    @staticmethod
    def item(menu, label, action=None):
        item = Gtk.MenuItem(label=label)
        if action is not None:
            item.connect("activate", lambda *_: action())
        menu.append(item)
        return item

    def submenu(self, label):
        item = self.item(self.menu, label)
        menu = Gtk.Menu()
        item.set_submenu(menu)
        return item, menu

    def choice(self, menu, label, action):
        item = Gtk.CheckMenuItem(label=label, draw_as_radio=True)

        def activate(_):
            if not self.updating and item.get_sensitive():
                action()
                # A GTK click toggles immediately; only keep confirmed state.
                self.window.sync_controls()

        item.connect("activate", activate)
        menu.append(item)
        return item

    def update(self, *, running, state, busy, count):
        if self.closed:
            return
        confirmed = state is not None and not busy
        selected = state.node if state is not None else None
        indices = list(range(1, min(count, QUICK_NODES) + 1))
        if count > QUICK_NODES and selected is not None and selected > QUICK_NODES:
            indices[-1] = selected
        key = (count, tuple(indices))
        self.updating = True
        try:
            if key != self.node_key:
                self.node_key = key
                for child in self.node_menu.get_children():
                    child.destroy()
                self.node_items = {node: self.choice(self.node_menu, f"Node {node}",
                                                     lambda node=node: self.window.apply_node(node))
                                   for node in indices}
                if count > QUICK_NODES:
                    self.item(self.node_menu, "All nodes…", self.window.show_window)
                self.node_menu.show_all()
            for node, item in self.node_items.items():
                item.set_active(confirmed and node == selected)
                item.set_sensitive(confirmed)
            for mode, item in self.mode_items.items():
                item.set_active(confirmed and mode == state.mode)
                item.set_sensitive(confirmed)
        finally:
            self.updating = False
        if busy:
            summary, icon = "Working…", "network-idle-symbolic"
        elif confirmed:
            summary, icon = f"{state.mode.title()} · Node {state.node}", "network-vpn-symbolic"
        elif running:
            summary, icon = "Status unconfirmed", "dialog-warning-symbolic"
        else:
            summary, icon = "Stopped", "network-offline-symbolic"
        self.summary.set_label(summary)
        self.indicator.set_icon_full(icon, f"CLAY · {summary}")
        self.nodes.set_sensitive(confirmed)
        self.modes.set_sensitive(confirmed)
        self.refresh.set_sensitive(running and not busy)
        self.stop.set_sensitive(running or busy)

    def update_system(self, label, enabled):
        self.system.set_label(label)
        self.system.set_sensitive(enabled)

    def watcher_ready(self, _source, result, *_):
        try:
            watcher = Gio.DBusProxy.new_for_bus_finish(result)
        except GLib.Error:
            return
        if self.closed:
            return
        self.watcher = watcher
        self.watcher_handlers = (
            watcher.connect("notify::g-name-owner", self.watcher_changed),
            watcher.connect("g-signal", self.host_signal),
            watcher.connect("g-properties-changed", self.host_properties),
        )
        self.check_host()

    def registration_changed(self, _indicator, connected):
        self.registered = connected
        self.check_host()

    def watcher_changed(self, *_):
        self.set_available(False)
        self.check_host()

    def host_signal(self, _proxy, _sender, signal, _parameters):
        if signal in ("StatusNotifierHostRegistered", "StatusNotifierHostUnregistered"):
            self.check_host()

    def host_properties(self, _proxy, changed, invalidated):
        if changed.lookup_value(HOST_PROPERTY, None) is not None or HOST_PROPERTY in invalidated:
            self.check_host()

    def check_host(self):
        self.probe += 1
        watcher = self.watcher
        if self.closed or not self.registered or watcher is None or watcher.get_name_owner() is None:
            self.set_available(False)
            return
        epoch, owner = self.probe, watcher.get_name_owner()

        def checked(proxy, result, *_):
            try:
                reply = proxy.call_finish(result)
                ready = (reply.get_type_string() == "(v)" and reply.unpack() == (True,)
                         and reply.get_child_value(0).get_variant().get_type_string() == "b")
            except (GLib.Error, TypeError):
                ready = False
            if not self.closed and epoch == self.probe and owner == proxy.get_name_owner():
                self.set_available(ready)

        watcher.call("org.freedesktop.DBus.Properties.Get", GLib.Variant("(ss)", (WATCHER, HOST_PROPERTY)),
                     Gio.DBusCallFlags.NO_AUTO_START, 1500, self.cancellable, checked)

    def set_available(self, available):
        if self.available != available:
            self.available = available
            self.window.tray_availability_changed(available)

    def close(self):
        self.closed = True
        self.cancellable.cancel()
        if self.watcher is not None:
            for handler in self.watcher_handlers:
                self.watcher.disconnect(handler)
        self.indicator.disconnect(self.registration_handler)
        self.indicator.set_status(self.api.IndicatorStatus.PASSIVE)
