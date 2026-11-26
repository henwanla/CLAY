#!/usr/bin/env python3
"""Test subscription I/O with local fixtures and an optional isolated Secret Service."""

import argparse
from email.message import Message
import gzip
import io
import os
from pathlib import Path
import stat
import tempfile
import threading

from session import DesktopError, MAX_PROFILE_BYTES
from subscriptions import Manager, SecretKey, Store, address, fetch, wipe


URL = "https://subscriptions.example.invalid/start?fixture=local-only"
PROFILE = bytearray(b"ss://aes-128-gcm:unused@127.0.0.1:9001#example\n"
                    b"trojan://synthetic-selected@127.0.0.1:9002#second\n")


def reject(action, expected):
    try:
        action()
    except DesktopError as error:
        assert expected in str(error) and URL not in str(error)
    else:
        raise AssertionError("invalid subscription was accepted")


def transport_checks():
    cancel = threading.Event()

    class Response(io.BytesIO):
        def __init__(self, status, body=b"", **headers):
            super().__init__(body)
            self.status, self.headers = status, Message()
            for key, value in headers.items():
                self.headers[key.replace("_", "-")] = str(value)

    def download(*responses):
        requests = []

        class Connection:
            def __init__(self, host, port):
                assert (host, port) == ("subscriptions.example.invalid", 443)
                self.response = next(stream)

            def request(self, method, target, headers):
                assert method == "GET" and set(headers) == {"User-Agent", "Accept-Encoding"}
                requests.append(target)

            def getresponse(self):
                return self.response

            def close(self):
                pass

        stream = iter(responses)
        return fetch(address(URL), cancel, connect=Connection), requests

    zipped = gzip.compress(PROFILE)
    result, requests = download(Response(302, Location="/nodes"),
                                Response(200, zipped, Content_Length=len(zipped), Content_Encoding="gzip"))
    assert result == PROFILE and requests == ["/start?fixture=local-only", "/nodes"]
    reject(lambda: download(Response(302, Location="https://elsewhere.example.invalid/")), "another origin")
    reject(lambda: download(*(Response(302, Location="/next") for _ in range(5))), "redirect limit")
    reject(lambda: download(Response(200, b"x", Content_Length=2)), "incomplete")
    reject(lambda: download(Response(200, b"x", Content_Length=-1)), "invalid size")
    reject(lambda: download(Response(200, b"x" * (MAX_PROFILE_BYTES + 1))), "2 MiB")
    reject(lambda: download(Response(200, gzip.compress(b"x" * (MAX_PROFILE_BYTES + 1)), Content_Encoding="gzip")), "2 MiB")
    cancel.set()
    reject(download, "stopped")
    for invalid in ("http://example.invalid/", "https://user@example.invalid/", "https://example.invalid/#local", "https://foo\\/bar"):
        reject(lambda: address(invalid), "HTTPS")
    print("PASS download policy: origin, redirects, size, gzip and cancellation")


class EphemeralKey:
    """Local macOS/portable smoke never needs a real keyring or D-Bus."""
    key = None

    def require(self):
        pass

    def read(self):
        return self.key

    def create(self):
        self.key = os.urandom(32)
        return self.key


def storage_checks(binary, directory, keyring):
    cancel = threading.Event()
    downloaded = PROFILE.copy()

    def local_download(url, event):
        assert url.url == URL and not event.is_set()
        return downloaded.copy()

    store = Store(directory, keyring)
    manager = Manager(binary, store, local_download)
    assert store.list() == []
    entry = manager.add("Fixture subscription", URL, cancel)
    assert entry.count == 2 and store.list() == [entry]
    record = store.file(entry.id)
    original = record.read_bytes()
    assert stat.S_IMODE(directory.stat().st_mode) == 0o700 and stat.S_IMODE(record.stat().st_mode) == 0o600
    assert all(clear not in original for clear in (b"Fixture subscription", b"local-only", b"synthetic-selected"))
    selected, preview, snapshot = manager.select(entry.id, cancel)
    assert selected == entry and tuple(node.kind for node in preview.nodes) == ("ss/tcp/aead", "trojan/tcp/tls") and snapshot == PROFILE
    downloaded[:] = b"not a profile"
    reject(lambda: manager.refresh(entry.id, cancel), "No supported nodes")
    assert record.read_bytes() == original
    downloaded[:] = PROFILE.replace(b"#second", b"#updated")
    refreshed = manager.refresh(entry.id, cancel)
    assert refreshed.revision != entry.revision and store.list() == [refreshed]
    assert snapshot == PROFILE  # Refresh must not replace a pending selection.
    wipe(snapshot)
    assert not any(snapshot)
    reject(lambda: store.refresh(entry, PROFILE, 2), "changed")
    another = manager.add("Another fixture", URL, cancel)
    store.file(another.id).write_bytes(record.read_bytes())
    assert not next(e for e in store.list() if e.id == another.id).readable
    reject(lambda: manager.select(another.id, cancel), "cache could not be read")
    store.remove(another.id)
    data = bytearray(record.read_bytes())
    data[-1] ^= 1
    record.write_bytes(data)
    assert not store.list()[0].readable
    store.remove(entry.id)
    assert store.list() == []
    print("PASS subscription cache: reload, refresh rollback, privacy, revision, authentication and removal")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path)
    parser.add_argument("--secret-service", action="store_true")
    options = parser.parse_args()
    transport_checks()
    if options.secret_service:
        fixture = Path(os.environ["CLAY_GNOME_FIXTURE"])
        assert Path.home() == fixture / "home" and os.environ["XDG_DATA_HOME"] == str(fixture / "data")
        assert os.environ["DBUS_SESSION_BUS_ADDRESS"]
        assert SecretKey().read() is None
    with tempfile.TemporaryDirectory(prefix="clay-subscription-smoke-") as directory:
        storage_checks(options.binary.resolve(strict=True), Path(directory) / "subscriptions",
                       SecretKey() if options.secret_service else EphemeralKey())
    if options.secret_service:
        assert len(SecretKey().read()) == 32  # A fresh lookup retrieves the persisted key.


if __name__ == "__main__":
    main()
