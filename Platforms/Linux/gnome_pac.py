"""GNOME's GSettings proxy adapter."""

import os
from pathlib import Path

from gi.repository import Gio, GLib

from desktop_pac import DesktopPac, Snapshot
from session import DesktopError


SCHEMA = "org.gnome.system.proxy"
KEYS = ("mode", "autoconfig-url")
MODES = ("none", "manual", "auto")
RECOVERY_NEEDED = ("GNOME proxy settings need recovery. If changed elsewhere, remove CLAY’s script address "
                   "in GNOME Network Proxy, then retry Restore GNOME proxy or Stop.")


class GnomeSettings:
    def __init__(self, schema):
        self.schema = schema

    @classmethod
    def open(cls):
        source = Gio.SettingsSchemaSource.get_default()
        schema = source.lookup(SCHEMA, True) if source is not None else None
        return cls(schema) if schema is not None and all(schema.has_key(key) for key in KEYS) else None

    def read(self):
        # Use fresh objects so a worker does not depend on the GTK thread
        # dispatching change notifications to a long-lived cached object.
        settings = Gio.Settings.new_full(self.schema, None, None)
        return Snapshot(tuple(settings.get_string(key) for key in KEYS),
                        tuple(value.unpack() if (value := settings.get_user_value(key)) is not None else None
                              for key in KEYS))

    def write(self, expected, values):
        settings = Gio.Settings.new_full(self.schema, None, None)
        if not all(settings.is_writable(key) for key in KEYS):
            raise DesktopError("GNOME proxy settings are locked. You can use the manual proxy address.")
        if self.read() != expected:
            raise DesktopError("GNOME proxy settings changed. Try again after reviewing them.")
        settings.delay()
        try:
            for key, value in zip(KEYS, values):
                if value is None:
                    settings.reset(key)
                elif not settings.set_value(key, GLib.Variant("s", value)):
                    raise DesktopError("GNOME did not accept the proxy settings.")
            settings.apply()
            Gio.Settings.sync()
        finally:
            settings.revert()  # Discard any partial staged changes if a key was locked.


class GnomePac(DesktopPac):
    name = "GNOME"
    automatic = "auto"
    valid_modes = MODES
    recovery_message = RECOVERY_NEEDED

    @classmethod
    def open(cls):
        desktops = os.environ.get("XDG_CURRENT_DESKTOP", "").lower().split(":")
        if "gnome" not in desktops:
            return None
        settings = GnomeSettings.open()
        if settings is None:
            return None
        return cls(settings, Path(GLib.get_user_state_dir()) / "CLAY" / "gnome-pac")
