"""GTK controls for opting into saved subscriptions while the proxy is stopped."""

import threading

from gi.repository import GLib, Gtk

from session import DesktopError
from subscriptions import wipe


class SubscriptionDialog(Gtk.Dialog):
    def __init__(self, owner, manager):
        super().__init__(title="Subscriptions", transient_for=owner, modal=True)
        self.owner = owner
        self.manager = manager
        self.cancel = threading.Event()
        self.busy = False
        self.closing = False
        self.entries = {}
        self.set_default_size(510, 300)
        self.add_button("Close", Gtk.ResponseType.CLOSE)
        self.connect("response", lambda *_: self.request_close())
        self.connect("delete-event", self.request_close)

        body = self.get_content_area()
        layout = Gtk.Box(orientation=Gtk.Orientation.VERTICAL, spacing=10, margin=12)
        body.add(layout)
        intro = Gtk.Label(label="Save an HTTPS subscription in a local cache protected by your desktop keyring. "
                                "CLAY only downloads it when you add or refresh it.", xalign=0, wrap=True)
        layout.pack_start(intro, False, False, 0)
        self.saved = Gtk.ComboBoxText()
        self.saved.connect("changed", lambda *_: self.sync_controls())
        layout.pack_start(self.saved, False, False, 0)
        choices = Gtk.Box(spacing=8)
        layout.pack_start(choices, False, False, 0)
        self.use = self.button(choices, "Use saved nodes", self.use_nodes)
        self.refresh = self.button(choices, "Refresh", self.refresh_saved)
        self.remove = self.button(choices, "Remove", self.remove_saved)

        layout.pack_start(Gtk.Separator(), False, False, 0)
        self.label = Gtk.Entry(placeholder_text="Name (for this device)", max_length=64)
        self.url = Gtk.Entry(placeholder_text="HTTPS subscription address", max_length=8192, visibility=False)
        for field in (self.label, self.url):
            layout.pack_start(field, False, False, 0)
            field.connect("changed", lambda *_: self.sync_controls())
        self.add = self.button(layout, "Download and save", self.add_saved)
        self.status = Gtk.Label(xalign=0, wrap=True)
        layout.pack_start(self.status, False, False, 0)
        self.run_task("Reading saved subscriptions…", self.manager.store.list,
                      lambda entries: self.show_entries(entries, "Choose a saved subscription or add one."))

    @staticmethod
    def button(box, label, handler):
        button = Gtk.Button(label=label)
        button.connect("clicked", handler)
        box.pack_start(button, False, False, 0)
        return button

    def selected(self):
        return self.entries.get(self.saved.get_active_id())

    def sync_controls(self):
        selected, ready = self.selected(), not self.busy and not self.closing
        for widget in (self.saved, self.label, self.url):
            widget.set_sensitive(ready)
        self.use.set_sensitive(ready and selected is not None and selected.readable)
        self.refresh.set_sensitive(self.use.get_sensitive())
        self.remove.set_sensitive(ready and selected is not None)
        self.add.set_sensitive(ready and bool(self.label.get_text().strip() and self.url.get_text().strip()))

    def show_entries(self, entries, message, item=None):
        previous = item.hex if item else self.saved.get_active_id()
        self.entries = {entry.id.hex: entry for entry in entries}
        self.saved.remove_all()
        for entry in entries:
            label = f"{entry.label} · {entry.count} nodes" if entry.readable else "Unreadable subscription"
            self.saved.append(entry.id.hex, label)
        if previous in self.entries:
            self.saved.set_active_id(previous)
        elif entries:
            self.saved.set_active(0)
        self.status.set_text(message)

    def run_task(self, message, action, completed, discard=lambda _: None):
        if self.busy or self.closing:
            return
        self.busy = True
        self.status.set_text(message)
        self.sync_controls()

        def work():
            try:
                result = action()
            except DesktopError as error:
                GLib.idle_add(finish, None, str(error))
            except Exception:
                GLib.idle_add(finish, None, "CLAY could not access the local subscription cache.")
            else:
                GLib.idle_add(finish, result, None)

        def finish(result, error):
            self.busy = False
            if self.closing:
                if result is not None:
                    discard(result)
                self.destroy()
            elif error is not None:
                self.status.set_text(error)
                self.sync_controls()
            else:
                completed(result)
                if not self.closing:
                    self.sync_controls()
            return GLib.SOURCE_REMOVE

        threading.Thread(target=work).start()

    def add_saved(self, *_):
        label, url = self.label.get_text(), self.url.get_text()
        self.url.set_text("")

        def added(entry):
            self.show_entries([entry, *self.entries.values()], "Saved. Choose Use saved nodes to load it.", entry.id)

        self.run_task("Downloading and checking nodes…", lambda: self.manager.add(label, url, self.cancel), added)

    def refresh_saved(self, *_):
        selected = self.selected()
        if selected is None or not selected.readable:
            return

        def refreshed(entry):
            others = [other for other in self.entries.values() if other.id != entry.id]
            self.show_entries([entry, *others], "Refreshed. Use saved nodes to load the new copy.", entry.id)

        self.run_task("Downloading and checking nodes…", lambda: self.manager.refresh(selected.id, self.cancel), refreshed)

    def remove_saved(self, *_):
        selected = self.selected()
        if selected is None:
            return

        def remove():
            self.manager.store.remove(selected.id)
            return selected.id

        def removed(item):
            self.owner.subscription_removed(item)
            self.show_entries([entry for entry in self.entries.values() if entry.id != item], "Removed from this device.")

        self.run_task("Removing saved subscription…", remove, removed, discard=self.owner.subscription_removed)

    def use_nodes(self, *_):
        selected = self.selected()
        if selected is None or not selected.readable:
            return

        def used(result):
            self.owner.apply_subscription(result)
            self.request_close()

        self.run_task("Checking saved nodes…", lambda: self.manager.select(selected.id, self.cancel), used,
                      discard=lambda result: wipe(result[2]))

    def request_close(self, *_):
        if not self.closing:
            self.closing = True
            self.cancel.set()
            self.url.set_text("")
            if self.busy:
                self.status.set_text("Stopping…")
                self.sync_controls()
            else:
                self.destroy()
        return True
