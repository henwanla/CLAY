"""Manage ownership and crash recovery for desktop proxy PAC settings."""

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

from session import DesktopError


LOCAL_URL = re.compile(r"http://127\.0\.0\.1:([1-9][0-9]{0,4})/[0-9a-f]{32}\.pac\Z")


class ReleaseError(DesktopError):
    pass


@dataclass(frozen=True)
class Snapshot:
    current: tuple
    user: tuple


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


class DesktopPac:
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

    @property
    def pending(self):
        return self.record is not None or os.path.lexists(self.journal)

    @property
    def serving(self):
        return self.server is not None

    def confirmed(self):
        if not self.serving or not self.server.thread.is_alive():
            return False
        pair = (self.automatic, self.server.url)
        return self.settings.read() == Snapshot(pair, pair)

    def enable(self, script):
        if self.pending or self.serving:
            raise ReleaseError(self.recovery_message)
        previous = self.settings.read()
        self.server = PacServer(script)
        record = {"version": 1, "previous": list(previous.user), "owned": self.server.url}
        try:
            self.save(record)
            self.record = record
            self.settings.write(previous, (self.automatic, self.server.url))
            if not self.confirmed():
                raise DesktopError(f"{self.name} did not confirm the new PAC configuration.")
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
            applied = (self.automatic, owned)
            live = self.settings.read()
            result = "restored"
            if live.user == applied and live.current == applied:
                self.settings.write(live, before)
                live = self.settings.read()
                if live.user != before or self.points_at_listener(live.current[1], owned):
                    raise ReleaseError(self.recovery_message)
            elif self.points_at_listener(live.current[1], owned) or self.points_at_listener(live.user[1], owned):
                # A still-referenced URL may be in use by a client; preserve
                # external edits and do not close the listener until resolved.
                raise ReleaseError(self.recovery_message)
            elif live.user != before:
                result = "external"
            self.journal.unlink(missing_ok=True)
            self.sync_directory()
            self.record = None
            self.close_server()
            return result
        except Exception:
            raise ReleaseError(self.recovery_message) from None

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
        if (record["version"] != 1 or old_mode not in (None, *self.valid_modes) or
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
            raise DesktopError(f"The existing {self.name} script address is too large to restore safely.")
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
