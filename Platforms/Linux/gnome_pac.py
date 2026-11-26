"""Own the current GNOME user's proxy mode and PAC URL while a session is live."""

from dataclasses import dataclass
import fcntl
import json
import os
from pathlib import Path
import re
import socketserver
import stat
import tempfile
import threading
import time
from urllib.parse import urlsplit
import uuid

from gi.repository import Gio, GLib

from session import DesktopError


SCHEMA = "org.gnome.system.proxy"
KEYS = ("mode", "autoconfig-url")
MODES = ("none", "manual", "auto")
RECOVERY_NEEDED = ("GNOME proxy settings need recovery. If changed elsewhere, remove CLAY’s script address "
                   "in GNOME Network Proxy, then retry Restore GNOME proxy or Stop.")
LOCAL_URL = re.compile(r"http://127\.0\.0\.1:([1-9][0-9]{0,4})/[0-9a-f]{32}\.pac\Z")


class ReleaseError(DesktopError):
    def __init__(self):
        super().__init__(RECOVERY_NEEDED)


@dataclass(frozen=True)
class Snapshot:
    current: tuple
    user: tuple


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


class PacHandler(socketserver.BaseRequestHandler):
    def handle(self):
        client = self.request
        client.settimeout(1)
        deadline = time.monotonic() + 3
        data = bytearray()
        try:
            while b"\r\n\r\n" not in data and len(data) < 8192 and time.monotonic() < deadline:
                chunk = client.recv(min(2048, 8192 - len(data)))
                if not chunk:
                    return
                data.extend(chunk)
            head, separator, _ = data.partition(b"\r\n\r\n")
            if not separator:
                return
            start, *headers = head.split(b"\r\n")
            request = start.split(b" ")
            hosts = [line[5:].strip() for line in headers if line[:5].lower() == b"host:"]
            found = (len(request) == 3 and request[0] in (b"GET", b"HEAD") and request[1] == self.server.path
                     and request[2] in (b"HTTP/1.0", b"HTTP/1.1")
                     and (hosts == [self.server.authority] or (not hosts and request[2] == b"HTTP/1.0")))
            body = self.server.script if found else b""
            status = b"200 OK" if found else b"404 Not Found"
            client.sendall(b"HTTP/1.1 " + status + b"\r\nContent-Type: application/x-ns-proxy-autoconfig\r\n"
                           + f"Content-Length: {len(body)}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n".encode()
                           + (body if request[0] == b"GET" else b""))
        except OSError:
            pass


class PacServer(socketserver.ThreadingTCPServer):
    daemon_threads = True
    block_on_close = False
    request_queue_size = 16

    def __init__(self, script):
        if not 0 < len(script) <= 16384:
            raise ValueError
        self.script = script
        self.slots = threading.BoundedSemaphore(16)
        self.path = f"/{uuid.uuid4().hex}.pac".encode()
        super().__init__(("127.0.0.1", 0), PacHandler)
        self.authority = f"127.0.0.1:{self.server_address[1]}".encode()
        self.url = "http://" + (self.authority + self.path).decode("ascii")
        self.thread = threading.Thread(target=self.serve_forever, kwargs={"poll_interval": 0.1}, daemon=True)
        self.thread.start()

    def process_request(self, request, client_address):
        if not self.slots.acquire(blocking=False):
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except Exception:
            self.slots.release()
            raise

    def process_request_thread(self, request, client_address):
        try:
            super().process_request_thread(request, client_address)
        finally:
            self.slots.release()

    def handle_error(self, _request, _client_address):
        pass  # Local PAC requests and socket errors are not logged.

    def close(self):
        self.shutdown()
        self.server_close()
        self.thread.join()


def private_file(path, flags):
    fd = os.open(path, flags | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC, 0o600)
    info = os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077 or info.st_nlink != 1:
        os.close(fd)
        raise OSError("Unsafe recovery file")
    return fd


class GnomePac:
    def __init__(self, settings, directory):
        self.settings = settings
        self.directory = directory
        self.journal = directory / "recovery.json"
        self.server = self.record = None
        directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        info = directory.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise OSError("Unsafe recovery directory")
        self.lock = private_file(directory / "owner.lock", os.O_RDWR | os.O_CREAT)
        try:
            fcntl.flock(self.lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except OSError:
            os.close(self.lock)
            raise

    @classmethod
    def open(cls):
        desktops = os.environ.get("XDG_CURRENT_DESKTOP", "").lower().split(":")
        if "gnome" not in desktops:
            return None
        settings = GnomeSettings.open()
        if settings is None:
            return None
        return cls(settings, Path(GLib.get_user_state_dir()) / "CLAY" / "gnome-pac")

    @property
    def pending(self):
        return self.record is not None or os.path.lexists(self.journal)

    @property
    def serving(self):
        return self.server is not None

    def confirmed(self):
        if not self.serving or not self.server.thread.is_alive():
            return False
        pair = ("auto", self.server.url)
        return self.settings.read() == Snapshot(pair, pair)

    def enable(self, script):
        if self.pending or self.serving:
            raise ReleaseError()
        previous = self.settings.read()
        self.server = PacServer(script)
        record = {"version": 1, "previous": list(previous.user), "owned": self.server.url}
        try:
            self.save(record)
            self.record = record
            self.settings.write(previous, ("auto", self.server.url))
            if not self.confirmed():
                raise DesktopError("GNOME did not confirm the new PAC configuration.")
        except Exception:
            self.release()
            raise

    def release(self):
        if not self.pending:
            self.close_server()
            return None
        try:
            record = self.record if self.record is not None else self.load()
            before, owned = tuple(record["previous"]), record["owned"]
            applied = ("auto", owned)
            live = self.settings.read()
            result = "restored"
            if live.user == applied and live.current == applied:
                self.settings.write(live, before)
                live = self.settings.read()
                if live.user != before or self.points_at_listener(live.current[1], owned):
                    raise ReleaseError()
            elif self.points_at_listener(live.current[1], owned) or self.points_at_listener(live.user[1], owned):
                # A still-referenced URL may be in use by a client; preserve
                # external edits and do not close the listener until resolved.
                raise ReleaseError()
            elif live.user != before:
                result = "external"
            self.journal.unlink(missing_ok=True)
            self.sync_directory()
            self.record = None
            self.close_server()
            return result
        except Exception:
            raise ReleaseError() from None

    @staticmethod
    def points_at_listener(url, owned):
        if not url:
            return False
        try:
            parts = urlsplit(url)
            return (parts.scheme == "http" and parts.hostname in ("localhost", "127.0.0.1", "127.1", "::1", "::ffff:127.0.0.1")
                    and parts.port == urlsplit(owned).port)
        except ValueError:
            return False

    def load(self):
        with os.fdopen(private_file(self.journal, os.O_RDONLY), "rb") as file:
            data = file.read(65537)
        if len(data) > 65536:
            raise ValueError
        record = json.loads(data)
        old_mode, old_url = record["previous"]
        match = LOCAL_URL.fullmatch(record["owned"])
        if (record["version"] != 1 or old_mode not in (None, *MODES) or
                not (old_url is None or isinstance(old_url, str) and len(old_url) <= 8192) or
                not match or int(match[1]) > 65535):
            raise ValueError
        return record

    def sync_directory(self):
        fd = os.open(self.directory, os.O_DIRECTORY | os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
        try:
            os.fsync(fd)
        finally:
            os.close(fd)

    def save(self, record):
        if record["previous"][1] is not None and len(record["previous"][1]) > 8192:
            raise DesktopError("The existing GNOME script address is too large to restore safely.")
        fd, temporary = tempfile.mkstemp(prefix=".recovery-", dir=self.directory)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as file:
                json.dump(record, file, ensure_ascii=False)
                file.flush()
                os.fsync(file.fileno())
            os.replace(temporary, self.journal)
            self.sync_directory()
        finally:
            Path(temporary).unlink(missing_ok=True)

    def close_server(self):
        if self.server is not None:
            self.server.close()
            self.server = None

    def close(self):
        self.close_server()
        os.close(self.lock)
