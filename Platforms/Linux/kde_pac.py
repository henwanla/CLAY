"""Plasma 6 PAC adapter, using the KConfig helper installed next to the CLI."""

import json
import os
from pathlib import Path
import stat
import subprocess

from gi.repository import GLib

from desktop_pac import DesktopPac, Snapshot
from session import DesktopError


HELPER = "clay-kde-settings"
MODES = ("0", "1", "2", "3", "4")
RECOVERY = ("Plasma proxy settings need recovery. If changed elsewhere, remove CLAY’s script address "
            "in System Settings → Proxy, then retry Restore Plasma proxy or Stop.")


def plasma6_session():
    desktops = os.environ.get("XDG_CURRENT_DESKTOP", "").lower().split(":")
    return "kde" in desktops and os.environ.get("KDE_SESSION_VERSION") == "6"


class KdeSettings:
    def __init__(self, binary):
        self.helper = Path(binary).with_name(HELPER)

    def available(self):
        try:
            info = self.helper.lstat()
            return (stat.S_ISREG(info.st_mode) and info.st_uid in (0, os.getuid()) and
                    not info.st_mode & 0o6022 and os.access(self.helper, os.X_OK))
        except OSError:
            return False

    def run(self, operation, data=None):
        if not self.available():
            raise DesktopError("The Plasma proxy helper is unavailable. You can use manual proxy.")
        env = {key: os.environ[key] for key in ("HOME", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS") if key in os.environ}
        env["PATH"] = "/usr/bin:/bin"
        try:
            result = subprocess.run([self.helper, operation], input=(b"" if data is None else json.dumps(data).encode("ascii")),
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=4, env=env, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise DesktopError("CLAY could not reach the Plasma proxy helper.") from None
        if result.returncode == 5:
            raise DesktopError("Plasma proxy settings changed. Review them and try again.")
        if result.returncode == 6:
            raise DesktopError("Plasma proxy settings are locked. You can use manual proxy.")
        if result.returncode != 0 or len(result.stdout) > 128 * 1024:
            raise DesktopError("CLAY could not read or safely update the Plasma proxy settings.")
        return result.stdout

    def read(self):
        def pair(values, *, user):
            if not isinstance(values, list) or len(values) != 2:
                raise ValueError
            mode, url = values
            if mode not in MODES and not (user and mode is None):
                raise ValueError
            if not (isinstance(url, str) and len(url) <= 8192 or user and url is None):
                raise ValueError
            return mode, url

        try:
            response = json.loads(self.run("read"))
            return Snapshot(pair(response["current"], user=False), pair(response["user"], user=True))
        except (ValueError, KeyError, TypeError):
            raise DesktopError("CLAY could not verify the Plasma proxy settings.") from None

    def write(self, expected, values):
        self.run("write", {"expected": {"current": expected.current, "user": expected.user}, "next": values})


class KdePac(DesktopPac):
    name = "Plasma"
    automatic = "2"
    valid_modes = MODES
    recovery_message = RECOVERY

    @classmethod
    def open(cls, binary):
        if not plasma6_session():
            return None
        settings = KdeSettings(binary)
        if not settings.available():
            return None
        return cls(settings, Path(GLib.get_user_state_dir()) / "CLAY" / "kde-pac")
