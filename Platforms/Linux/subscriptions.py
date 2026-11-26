"""Explicit HTTPS downloads and per-user encrypted subscription snapshots."""

from base64 import b64decode, b64encode
from contextlib import contextmanager
from dataclasses import dataclass, replace
import fcntl
import gzip
import http.client
import io
import json
import os
from pathlib import Path
import secrets
import ssl
import stat
import subprocess
import tempfile
import time
import unicodedata
from urllib.parse import quote, urljoin, urlsplit, urlunsplit
from uuid import UUID, uuid4

from session import DesktopError, MAX_PROFILE_BYTES, inspect


LIMIT = 12
MAX_NAME = 64
MAX_URL = 8192
MAX_RECORD = 3 * 1024 * 1024
TOOL = Path("/usr/bin/secret-tool")
ATTRIBUTES = ("application", "org.clay.desktop", "purpose", "subscriptions-v1")
KEYRING_UNAVAILABLE = "Unlock your desktop keyring to use subscriptions. CLAY cannot store subscriptions without it."


@dataclass(frozen=True)
class Address:
    url: str
    host: str
    port: int
    target: str


def address(value):
    value = value.strip()
    try:
        if (not 0 < len(value) <= MAX_URL or not value.lower().startswith("https://") or
                any(c.isspace() or unicodedata.category(c).startswith("C") for c in value) or
                any(c in value for c in ("#", chr(92)))):
            raise ValueError
        parts = urlsplit(value)
        if not parts.hostname or "@" in parts.netloc or "%" in parts.hostname:
            raise ValueError
        host = parts.hostname.encode("idna").decode("ascii").lower()
        port = 443 if parts.port is None else parts.port
        if not 0 < port <= 65535:
            raise ValueError
        authority = f"[{host}]" if ":" in host else host
        if port != 443:
            authority += f":{port}"
        path = quote(parts.path or "/", safe="/%:@!$&'()*+,;=-._~")
        query = quote(parts.query, safe="/%?:@!$&'()*+,;=-._~[]")
        url = urlunsplit(("https", authority, path, query, ""))
        if len(url) > MAX_URL:
            raise ValueError
        return Address(url, host, port, path + (f"?{query}" if query else ""))
    except (UnicodeError, ValueError):
        raise DesktopError("Enter a valid HTTPS subscription address.") from None


def name(value):
    value = value.strip()
    if not 0 < len(value) <= MAX_NAME or any(unicodedata.category(c) in {"Cc", "Cf", "Cs", "Zl", "Zp"} for c in value):
        raise DesktopError("Enter a subscription name of up to 64 characters.")
    return value


def _continue(cancel, deadline):
    if cancel is not None and cancel.is_set():
        raise DesktopError("Operation stopped.")
    if time.monotonic() >= deadline:
        raise DesktopError("The subscription download timed out.")


def _bounded(read, cancel, deadline):
    result = bytearray()
    try:
        while True:
            _continue(cancel, deadline)
            chunk = read(min(8192, MAX_PROFILE_BYTES + 1 - len(result)))
            _continue(cancel, deadline)
            if not chunk:
                return result
            if len(result) + len(chunk) > MAX_PROFILE_BYTES:
                raise DesktopError("The subscription exceeded 2 MiB.")
            result.extend(chunk)
    except BaseException:
        wipe(result)
        raise


def fetch(start, cancel, *, connect=None):
    # HTTPSConnection has no cookie jar, redirect handler or inherited proxy.
    if connect is None:
        # Do not inherit SSLKEYLOGFILE through create_default_context().
        context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
        context.load_default_certs()
        connect = lambda host, port: http.client.HTTPSConnection(host, port, timeout=5, context=context)
    current = start
    deadline = time.monotonic() + 25
    try:
        for hop in range(5):
            _continue(cancel, deadline)
            connection = connect(current.host, current.port)
            try:
                connection.request("GET", current.target, headers={"User-Agent": "CLAY", "Accept-Encoding": "gzip, identity"})
                with connection.getresponse() as response:
                    if response.status in (301, 302, 303, 307, 308):
                        locations = response.headers.get_all("Location", [])
                        try:
                            if (hop == 4 or len(locations) != 1 or not 0 < len(locations[0]) <= MAX_URL or
                                    any(c in locations[0] for c in ("#", chr(92))) or
                                    any(c.isspace() or unicodedata.category(c).startswith("C") for c in locations[0])):
                                raise ValueError
                            next_address = address(urljoin(current.url, locations[0]))
                            if (next_address.host, next_address.port) != (current.host, current.port):
                                raise ValueError
                        except (ValueError, DesktopError):
                            raise DesktopError("The subscription redirected to another origin or exceeded the redirect limit.") from None
                        current = next_address
                        continue
                    if response.status != 200:
                        raise DesktopError("The subscription server did not return a usable response.")
                    sizes = response.headers.get_all("Content-Length", [])
                    expected = None
                    if sizes:
                        size = sizes[0].strip()
                        if (len(sizes) != 1 or response.headers.get_all("Transfer-Encoding") or
                                not size.isascii() or not size.isdecimal() or len(size) > 10):
                            raise DesktopError("The subscription returned an invalid size.")
                        expected = int(size)
                        if expected > MAX_PROFILE_BYTES:
                            raise DesktopError("The subscription exceeded 2 MiB.")
                    encodings = response.headers.get_all("Content-Encoding", [])
                    coding = "identity" if not encodings else encodings[0].strip().lower() if len(encodings) == 1 else ""
                    if coding not in ("identity", "gzip"):
                        raise DesktopError("The subscription returned an unsupported encoding.")
                    wire = _bounded(response.read1, cancel, deadline)
                    if expected is not None and len(wire) != expected:
                        wipe(wire)
                        raise DesktopError("The subscription download was incomplete.")
                    if coding == "identity":
                        return wire
                    try:
                        with io.BytesIO(wire) as compressed, gzip.GzipFile(fileobj=compressed) as body:
                            return _bounded(body.read1, cancel, deadline)
                    finally:
                        wipe(wire)
            finally:
                connection.close()
    except (OSError, EOFError, ValueError, http.client.HTTPException):
        raise DesktopError("Could not download the subscription. Check the address and connection.") from None
    raise DesktopError("The subscription redirected too many times.")


def wipe(buffer):
    if buffer is not None:
        buffer[:] = b'\x00' * len(buffer)


class SecretKey:
    @staticmethod
    def require():
        if not os.access(TOOL, os.X_OK):
            raise DesktopError(KEYRING_UNAVAILABLE)

    @staticmethod
    def _run(args, payload=None):
        try:
            service_env = {key: os.environ[key] for key in ("HOME", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR",
                           "DISPLAY", "WAYLAND_DISPLAY", "XAUTHORITY", "LANG", "LC_ALL") if key in os.environ}
            return subprocess.run([TOOL, *args], input=payload if payload is not None else b"", capture_output=True,
                                  timeout=12, env=service_env, check=False)
        except (OSError, subprocess.TimeoutExpired):
            raise DesktopError(KEYRING_UNAVAILABLE) from None

    def read(self):
        self.require()
        lookup = self._run(("lookup", *ATTRIBUTES))
        if lookup.returncode == 1 and not lookup.stdout and not lookup.stderr:
            return None
        if lookup.returncode == 0 and len(lookup.stdout) <= 48:
            try:
                decoded = b64decode(lookup.stdout.rstrip(b'\n'), validate=True)
                if len(decoded) == 32:
                    return decoded
            except ValueError:
                pass
        raise DesktopError(KEYRING_UNAVAILABLE)

    def create(self):
        key = secrets.token_bytes(32)
        saved = self._run(("store", "--label=CLAY subscription encryption key", *ATTRIBUTES), b64encode(key))
        if saved.returncode != 0 or not secrets.compare_digest(key, self.read() or b""):
            raise DesktopError(KEYRING_UNAVAILABLE)
        return key


@dataclass(frozen=True)
class Entry:
    id: UUID
    revision: UUID | None = None
    label: str = ""
    count: int = 0
    updated: int = 0

    @property
    def readable(self):
        return self.revision is not None


@dataclass
class Data:
    entry: Entry
    url: Address
    source: bytearray

    def __enter__(self):
        return self

    def __exit__(self, *_):
        wipe(self.source)


class Store:
    def __init__(self, directory=None, keyring=None):
        data_home = os.environ.get("XDG_DATA_HOME")
        base = Path(data_home) if data_home and Path(data_home).is_absolute() else Path.home() / ".local/share"
        self.directory = Path(directory) if directory is not None else base / "clay/subscriptions-v1"
        self.keyring = keyring if keyring is not None else SecretKey()

    def require(self):
        self.aes()
        self.keyring.require()

    @staticmethod
    def aes():
        try:
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM
            return AESGCM
        except ImportError:
            raise DesktopError("Install the desktop subscription security dependencies to save subscriptions.") from None

    @contextmanager
    def locked(self):
        self.directory.mkdir(mode=0o700, parents=True, exist_ok=True)
        self.check_private(self.directory.lstat(), stat.S_ISDIR)
        fd = os.open(self.directory / "owner.lock", os.O_RDWR | os.O_CREAT | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600)
        try:
            self.check_private(os.fstat(fd), stat.S_ISREG)
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            yield
        finally:
            os.close(fd)

    @staticmethod
    def check_private(info, kind):
        if not kind(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise DesktopError("CLAY's subscription directory or file is not private.")

    def ids(self):
        result = []
        for file in self.directory.glob("*.sealed"):
            try:
                item = UUID(hex=file.stem)
            except ValueError:
                continue
            if item.hex != file.stem or not item.int:
                continue
            result.append(item)
            if len(result) > LIMIT:
                raise DesktopError("CLAY found too many subscription records.")
        return result

    def list(self):
        with self.locked():
            ids = self.ids()
            if not ids:
                return []
            cipher = self.cipher(create=False)
            entries = []
            for item in ids:
                try:
                    with self._read(item, cipher) as data:
                        entries.append(data.entry)
                except DesktopError:
                    entries.append(Entry(item))
            return sorted(entries, key=lambda e: (-e.updated, e.id.hex))

    def read(self, item):
        with self.locked():
            return self._read(item, self.cipher(create=False))

    def add(self, label, url, source, count):
        with self.locked():
            ids = self.ids()
            if len(ids) >= LIMIT:
                raise DesktopError("CLAY can save up to 12 subscriptions.")
            entry = Entry(uuid4(), uuid4(), name(label), count, time.time_ns() // 1_000_000)
            return self._save(entry, url, source, self.cipher(create=not ids))

    def refresh(self, original, source, count):
        with self.locked():
            cipher = self.cipher(create=False)
            with self._read(original.id, cipher) as current:
                if current.entry.revision != original.revision:
                    raise DesktopError("The subscription changed. Open the list again before refreshing.")
                updated = max(original.updated + 1, time.time_ns() // 1_000_000)
                return self._save(replace(current.entry, revision=uuid4(), count=count, updated=updated), current.url, source, cipher)

    def remove(self, item):
        with self.locked():
            self.file(item).unlink(missing_ok=True)

    def cipher(self, *, create):
        aes = self.aes()
        key = self.keyring.read()
        if key is None and create:
            key = self.keyring.create()
        if key is None:
            raise DesktopError(KEYRING_UNAVAILABLE)
        return aes(key)

    def file(self, item):
        return self.directory / f"{item.hex}.sealed"

    @staticmethod
    def binding(item):
        return b"CLAY.linux.subscriptions.v1:" + item.bytes

    def _read(self, item, cipher):
        try:
            with os.fdopen(os.open(self.file(item), os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW | os.O_NONBLOCK), "rb") as stream:
                self.check_private(os.fstat(stream.fileno()), stat.S_ISREG)
                sealed = stream.read(MAX_RECORD + 1)
            if not 30 <= len(sealed) <= MAX_RECORD or sealed[0] != 1:
                raise ValueError
            record = json.loads(cipher.decrypt(sealed[1:13], sealed[13:], self.binding(item)))
            count, updated = record["count"], record["updated"]
            if type(count) is not int or not 1 <= count <= 100 or type(updated) is not int or updated <= 0:
                raise ValueError
            entry = Entry(item, UUID(hex=record["revision"]), name(record["label"]), count, updated)
            url = address(record["url"])
            source = b64decode(record["source"], validate=True)
            if not 0 < len(source) <= MAX_PROFILE_BYTES:
                raise ValueError
            return Data(entry, url, bytearray(source))
        except Exception:
            raise DesktopError("The subscription cache could not be read.") from None

    def _save(self, entry, url, source, cipher):
        if not 0 < len(source) <= MAX_PROFILE_BYTES or not 1 <= entry.count <= 100:
            raise DesktopError("The subscription has no usable nodes.")
        clear = json.dumps({"revision": entry.revision.hex, "label": entry.label, "count": entry.count,
                            "updated": entry.updated, "url": url.url, "source": b64encode(source).decode("ascii")},
                           ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        nonce = secrets.token_bytes(12)
        sealed = b'\x01' + nonce + cipher.encrypt(nonce, clear, self.binding(entry.id))
        if len(sealed) > MAX_RECORD:
            raise DesktopError("The subscription cache is too large.")
        fd, temporary = tempfile.mkstemp(dir=self.directory, prefix=".pending-")
        try:
            with os.fdopen(fd, "wb") as stream:
                stream.write(sealed)
                stream.flush()
                os.fsync(stream.fileno())
            os.replace(temporary, self.file(entry.id))
            with self._read(entry.id, cipher) as confirmed:
                if confirmed.entry != entry:
                    raise DesktopError("The subscription cache could not be confirmed.")
        finally:
            Path(temporary).unlink(missing_ok=True)
        return entry


class Manager:
    def __init__(self, binary, store, download=fetch):
        self.binary, self.store, self.download = binary, store, download

    def add(self, label, url, cancel):
        label, url = name(label), address(url)
        self.store.require()
        source = self.download(url, cancel)
        try:
            preview = inspect(self.binary, source=source, cancel=cancel)
            if cancel.is_set():
                raise DesktopError("Operation stopped.")
            return self.store.add(label, url, source, len(preview.nodes))
        finally:
            wipe(source)

    def refresh(self, item, cancel):
        with self.store.read(item) as old:
            source = self.download(old.url, cancel)
            try:
                preview = inspect(self.binary, source=source, cancel=cancel)
                if cancel.is_set():
                    raise DesktopError("Operation stopped.")
                return self.store.refresh(old.entry, source, len(preview.nodes))
            finally:
                wipe(source)

    def select(self, item, cancel):
        with self.store.read(item) as data:
            preview = inspect(self.binary, source=data.source, cancel=cancel)
            return data.entry, preview, data.source.copy()
