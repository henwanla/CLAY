"""Private adapter around clay-portable's line protocol."""

from contextlib import contextmanager, nullcontext
from dataclasses import dataclass
import hashlib
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import tempfile
import time


MODES = ("rule", "global", "direct")
MAX_PROFILES = 100
MAX_PROFILE_BYTES = 2 * 1024 * 1024
CHILD_ENV = {"LANG": "C"}
READY = re.compile(rb"mihomo=ready proxy=127\.0\.0\.1:([1-9][0-9]{0,4}) controller=127\.0\.0\.1:([1-9][0-9]{0,4})")
STATUS = re.compile(rb"mode=(rule|global|direct) node=([1-9][0-9]{0,2})")
NODE = re.compile(rb"node=([1-9][0-9]{0,2}) ([a-z0-9-]{1,24}/[a-z0-9-]{1,16}/[a-z0-9-]{1,16})")


class DesktopError(Exception):
    """Only fixed messages are safe to display."""


@dataclass(frozen=True)
class Preview:
    nodes: tuple[str, ...]
    digest: str
    skipped: int


@dataclass(frozen=True)
class State:
    mode: str
    node: int
    port: int


@contextmanager
def snapshot(path, expected_digest=None):
    """Inspect and start with the same bytes even if the source is edited."""
    try:
        # O_NONBLOCK keeps FIFOs from blocking before fstat rejects them.
        with os.fdopen(os.open(path, os.O_RDONLY | os.O_NONBLOCK), "rb") as source:
            if not stat.S_ISREG(os.fstat(source.fileno()).st_mode):
                raise OSError
            content = source.read(MAX_PROFILE_BYTES + 1)
    except OSError:
        raise DesktopError("Choose a readable local profile file.") from None
    if len(content) > MAX_PROFILE_BYTES:
        raise DesktopError("The profile file must be 2 MiB or smaller.")
    digest = hashlib.sha256(content).hexdigest()
    if expected_digest is not None and expected_digest != digest:
        raise DesktopError("The profile file changed. Load it again before starting.")
    with tempfile.TemporaryDirectory(prefix="clay-desktop-") as directory:
        file = Path(directory) / "profile"
        with os.fdopen(os.open(file, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600), "wb") as target:
            target.write(content)
        del content
        yield file, digest


class Lines:
    def __init__(self, stream):
        self.stream = stream
        self.buffer = bytearray()

    def read(self, deadline, cancel=None):
        with selectors.DefaultSelector() as selector:
            selector.register(self.stream, selectors.EVENT_READ)
            while True:
                if cancel is not None and cancel.is_set():
                    raise DesktopError("Operation stopped.")
                end = self.buffer.find(b"\n")
                if 0 <= end <= 256:
                    line = bytes(self.buffer[:end])
                    del self.buffer[:end + 1]
                    return line
                if len(self.buffer) > 256:
                    raise DesktopError("The local command sent an invalid response.")
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise DesktopError("The local command did not respond in time.")
                if selector.select(min(remaining, 0.1)):
                    data = os.read(self.stream.fileno(), 256)
                    if not data:
                        if self.buffer:
                            raise DesktopError("The local command sent an incomplete response.")
                        return None
                    self.buffer.extend(data)


def source_args(path, source, expected=None):
    if source is None:
        return snapshot(path, expected)
    if not 0 < len(source) <= MAX_PROFILE_BYTES:
        raise DesktopError("The profile must be nonempty and 2 MiB or smaller.")
    digest = hashlib.sha256(source).hexdigest()
    if expected is not None and expected != digest:
        raise DesktopError("The cached profile changed. Choose the saved nodes again.")
    return nullcontext(("--profile-stdin", digest))


def send_frame(process, source, deadline, cancel):
    fd = process.stdin.fileno()
    try:
        os.set_blocking(fd, False)
        with selectors.DefaultSelector() as selector:
            selector.register(fd, selectors.EVENT_WRITE)
            for data in (len(source).to_bytes(4, "big"), source):
                with memoryview(data) as view:
                    offset = 0
                    while offset < len(view):
                        if cancel is not None and cancel.is_set():
                            raise DesktopError("Operation stopped.")
                        remaining = deadline - time.monotonic()
                        if remaining <= 0:
                            raise DesktopError("The local command did not read the profile in time.")
                        if selector.select(min(remaining, 0.1)):
                            try:
                                offset += os.write(fd, view[offset:offset + 65536])
                            except BlockingIOError:
                                continue
    except OSError:
        raise DesktopError("The local command could not read the cached profile.") from None
    finally:
        os.set_blocking(fd, True)


def inspect(binary, path=None, cancel=None, *, source=None):
    with source_args(path, source) as (profile, digest):
        with launch(binary, "inspect", profile, "--numbered") as process:
            try:
                lines = Lines(process.stdout)
                deadline = time.monotonic() + 8
                if source is not None:
                    send_frame(process, source, deadline, cancel)
                process.stdin.close()
                header = re.fullmatch(rb"nodes=([1-9][0-9]{0,2})", lines.read(deadline, cancel) or b"")
                if not header or int(header[1]) > MAX_PROFILES:
                    raise DesktopError("No supported nodes were found in this profile.")
                nodes = []
                for index in range(1, int(header[1]) + 1):
                    node = NODE.fullmatch(lines.read(deadline, cancel) or b"")
                    if not node or int(node[1]) != index:
                        raise DesktopError("The node list returned by the local command is invalid.")
                    nodes.append(node[2].decode("ascii"))
                skipped = 0
                for _ in range(16):
                    line = lines.read(deadline, cancel)
                    if line is None:
                        if process.wait(timeout=1) == 0:
                            return Preview(tuple(nodes), digest, skipped)
                        break
                    issue = re.fullmatch(rb"skipped\.[A-Za-z]{1,32}=([0-9]{1,10})", line)
                    if not issue:
                        break
                    skipped += int(issue[1])
                raise DesktopError("The local command could not inspect the profile.")
            finally:
                if process.poll() is None:
                    process.kill()  # Offline inspection never launches an engine.


def launch(binary, *arguments):
    try:
        if not Path(binary).is_absolute():
            raise OSError
        return subprocess.Popen([binary, *arguments], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                stderr=subprocess.DEVNULL, env=CHILD_ENV, bufsize=0)
    except OSError:
        raise DesktopError("Could not run the supplied clay-portable binary.") from None


def default_pac(binary, port, cancel=None):
    if not isinstance(port, int) or not 1 <= port <= 65535:
        raise DesktopError("The local proxy has no confirmed port.")
    # No custom rules go into the system PAC. The default PAC keeps local
    # hosts direct and the same running core handles all other routing modes.
    with tempfile.NamedTemporaryFile(prefix="clay-pac-rules-") as rules:
        with launch(binary, "pac-script", rules.name, str(port)) as child:
            output = bytearray()
            deadline = time.monotonic() + 5
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(child.stdout, selectors.EVENT_READ)
                    while time.monotonic() < deadline:
                        if cancel is not None and cancel.is_set():
                            raise DesktopError("Operation stopped.")
                        if not selector.select(0.1):
                            continue
                        data = os.read(child.stdout.fileno(), 1024)
                        if not data:
                            if child.wait(timeout=1) == 0 and output:
                                return bytes(output)
                            break
                        output.extend(data)
                        if len(output) > 16384:
                            break
                raise DesktopError("Could not generate the default PAC script.")
            finally:
                if child.poll() is None:
                    child.kill()


class Session:
    def __init__(self, binary, cancel, before_stop=None):
        self.binary = binary
        self.cancel = cancel
        self.before_stop = before_stop
        self.process = None
        self.state = None

    def start(self, path, preview, node, engine, digest, mode, rules=None, *, source=None):
        if self.process is not None:
            raise DesktopError("Stop the current session first.")
        if mode not in MODES or not 1 <= node <= len(preview.nodes):
            raise DesktopError("Choose a node and routing mode first.")
        if not re.fullmatch(r"[0-9a-fA-F]{64}", digest):
            raise DesktopError("Enter the expected SHA-256 as 64 hexadecimal characters.")
        if not engine or not Path(engine).is_absolute():
            raise DesktopError("Choose a local Mihomo executable.")
        self.count = len(preview.nodes)
        try:
            with source_args(path, source, preview.digest) as (profile, _):
                command = ["mihomo-run", profile, str(node), engine, digest, "--all-nodes", "--interactive", "--mode", mode]
                if rules:
                    command += ["--pac-rules", rules]
                self.process = launch(self.binary, *command)
                self.lines = Lines(self.process.stdout)
                deadline = time.monotonic() + 15
                if source is not None:
                    send_frame(self.process, source, deadline, self.cancel)
                line = self.lines.read(deadline, self.cancel)
                if line is None:
                    raise DesktopError("Mihomo did not start. Check the executable, SHA-256, and selected rules file.")
                ready = READY.fullmatch(line)
                if not ready or any(int(port) > 65535 for port in ready.groups()) or ready[1] == ready[2]:
                    raise DesktopError("The local command did not confirm two loopback listeners.")
                self.port = int(ready[1])
            state = self.refresh()
            if (state.mode, state.node) != (mode, node):
                raise DesktopError("Mihomo did not confirm the requested node and routing mode.")
            return state
        except Exception:
            self.stop(interrupt=True)
            raise

    def request(self, command):
        if self.process is None or self.process.poll() is not None:
            raise DesktopError("The local session has ended.")
        try:
            self.process.stdin.write(command + b"\n")
            reply = self.lines.read(time.monotonic() + 8, self.cancel)
        except (DesktopError, OSError):
            # If a reply was lost, a future command might read that stale reply.
            self.stop(interrupt=True)
            raise DesktopError("The local command stopped responding. Start the session again.") from None
        if reply is None:
            self.stop(interrupt=True)
            raise DesktopError("The local session has ended.")
        return reply

    def refresh(self):
        self.state = None
        data = STATUS.fullmatch(self.request(b"status"))
        if not data or int(data[2]) > self.count:
            raise DesktopError("Mihomo could not confirm the active routing mode and node.")
        self.state = State(data[1].decode("ascii"), int(data[2]), self.port)
        return self.state

    def change(self, *, node=None, mode=None):
        previous = self.state
        if previous is None:
            raise DesktopError("Refresh the session before changing it.")
        if node is not None and mode is None and 1 <= node <= self.count:
            key, value = b"node", str(node).encode("ascii")
        elif mode in MODES and node is None:
            key, value = b"mode", mode.encode("ascii")
        else:
            raise DesktopError("Choose a supported node or mode.")
        self.state = None
        reply = self.request(key + b" " + value)
        if reply != key + b"=" + value:
            raise DesktopError("Mihomo did not confirm the change. Refresh before continuing.")
        state = self.refresh()
        if (state.mode, state.node) != (mode or previous.mode, node or previous.node):
            self.state = None
            raise DesktopError("Mihomo did not confirm the change. Refresh before continuing.")
        return state

    def stop(self, interrupt=False):
        self.state = None
        child = self.process
        if child is None:
            return
        if self.before_stop is not None:
            self.before_stop()
        if child.poll() is None:
            if not interrupt and not child.stdin.closed:
                try:
                    child.stdin.write(b"quit\n")
                except OSError:
                    pass
            child.stdin.close()
            if not interrupt:
                try:
                    child.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    pass
            if child.poll() is None:
                child.terminate()  # The CLI cleans up its own child group.
                try:
                    child.wait(timeout=6)
                except subprocess.TimeoutExpired:
                    raise DesktopError("The local session is still stopping. Retry Stop.") from None
        child.stdin.close()
        child.stdout.close()
        self.process = None
