#if os(Linux)
import CLAYCore
import Dispatch
import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

private func closeFD(_ fd: Int32) { _ = close(fd) }
private func readFD(_ fd: Int32, _ buffer: UnsafeMutableRawPointer, _ count: Int) -> Int { read(fd, buffer, count) }
private func pollFD(_ descriptor: inout pollfd, _ timeout: Int32) -> Int32 { poll(&descriptor, 1, timeout) }

enum LinuxMihomoError: Error {
    case noSuchNode, badFingerprint, executable, digest, privateFiles, signals, launch, ports, timeout, childExited

    var message: String {
        switch self {
        case .noSuchNode: return "The selected node number is not in the imported list."
        case .badFingerprint: return "Provide an expected SHA-256 as 64 hexadecimal characters."
        case .executable: return "Unable to stage the supplied Mihomo executable."
        case .digest: return "Mihomo verification failed. Confirm the expected SHA-256 and /usr/bin/sha256sum."
        case .privateFiles: return "Unable to prepare the private Mihomo run directory."
        case .signals: return "Unable to install termination handling."
        case .launch: return "Unable to start the verified Mihomo executable."
        case .ports: return "The requested loopback ports are unavailable."
        case .timeout: return "Mihomo did not establish its own loopback listeners in time. Linux /proc access is required."
        case .childExited: return "Mihomo exited before this session finished."
        }
    }

    var exitCode: Int32 {
        switch self {
        case .noSuchNode, .badFingerprint, .executable, .digest: return 65
        default: return 69
        }
    }
}

enum LinuxMihomoRuntime {
    /// Returns the signal exit code only after the child and its private state are gone.
    static func run(node: NodeProfile, executable: String, fingerprint: String, proxyPort: Int?, controlPort: Int?) throws -> Int32 {
        guard fingerprint.utf8.count == 64, fingerprint.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
        else { throw LinuxMihomoError.badFingerprint }
        guard proxyPort == nil || proxyPort != controlPort else { throw LinuxMihomoError.ports }

        // main() runs on this thread. Block the signals before creating a
        // child; a synchronous signal fd prevents interrupting cleanup code.
        let signals = try TerminationSignals()
        defer { signals.close() }
        let directory = try privateDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let engine = directory.appendingPathComponent("mihomo").path
        let source = URL(fileURLWithPath: executable).path
        try stageBinary(source, to: engine)
        if let interrupted = signals.poll(timeout: 0) { return interrupted }
        if let interrupted = try verifyBinary(engine, fingerprint: fingerprint.lowercased(), directory: directory.path, signals: signals) { return interrupted }

        let proxy = try PortReservation(proxyPort)
        let control = try PortReservation(controlPort)
        let config: Data
        do {
            config = try CoreConfig.make(nodes: [node], active: node, proxyPort: proxy.port,
                                         controlPort: control.port, secret: UUID().uuidString + UUID().uuidString)
            try writePrivateFile(config, to: directory.appendingPathComponent("clay.json").path)
        } catch { throw LinuxMihomoError.privateFiles }

        let null = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { throw LinuxMihomoError.launch }
        defer { closeFD(null) }
        if let interrupted = signals.poll(timeout: 0) { return interrupted }
        proxy.release()
        control.release()
        let child = try Child(executable: engine, arguments: ["-d", directory.path, "-f", directory.appendingPathComponent("clay.json").path],
                              home: directory.path, stdin: null, stdout: null, stderr: null)
        defer { child.stop() }

        let deadline = DispatchTime.now() + .seconds(6)
        let ports: Set<Int> = [proxy.port, control.port]
        var ready = false
        while DispatchTime.now() < deadline {
            if let interrupted = signals.poll(timeout: 35) { return interrupted }
            guard child.isAlive() else { throw LinuxMihomoError.childExited }
            if childOwnsListeners(pid: child.pid, ports: ports), child.isAlive() { ready = true; break }
        }
        guard ready else { throw LinuxMihomoError.timeout }
        if let interrupted = signals.poll(timeout: 0) { return interrupted }
        FileHandle.standardOutput.write(Data("mihomo=ready proxy=127.0.0.1:\(proxy.port) controller=127.0.0.1:\(control.port)\n".utf8))
        while true {
            if let interrupted = signals.poll(timeout: 200) { return interrupted }
            guard child.isAlive() else { throw LinuxMihomoError.childExited }
        }
    }

    private static func privateDirectory() throws -> URL {
        // Use a fixed writable parent and mkdtemp's atomic 0700 creation.
        var template = Array("/tmp/clay-linux.XXXXXX".utf8CString)
        let directory = template.withUnsafeMutableBufferPointer { buffer in
            mkdtemp(buffer.baseAddress!).map { String(cString: $0) }
        }
        guard let directory else { throw LinuxMihomoError.privateFiles }
        return URL(fileURLWithPath: directory, isDirectory: true)
    }

    private static func stageBinary(_ source: String, to destination: String) throws {
        let input = open(source, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard input >= 0 else { throw LinuxMihomoError.executable }
        defer { closeFD(input) }
        var info = stat()
        guard fstat(input, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              info.st_mode & 0o111 != 0, (1...512 * 1024 * 1024).contains(info.st_size) else { throw LinuxMihomoError.executable }
        let output = open(destination, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o700)
        guard output >= 0 else { throw LinuxMihomoError.executable }
        defer { closeFD(output) }
        do {
            // Do not reopen the source path after checking it. Copy at most its
            // original extent and refuse a source that grew during the copy.
            var remaining = Int(info.st_size), buffer = [UInt8](repeating: 0, count: 1024 * 1024)
            while remaining > 0 {
                let amount = min(buffer.count, remaining)
                let count = buffer.withUnsafeMutableBytes { readFD(input, $0.baseAddress!, amount) }
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw LinuxMihomoError.executable }
                try buffer.withUnsafeBytes {
                    try writeAll(output, bytes: UnsafeRawBufferPointer(start: $0.baseAddress, count: count))
                }
                remaining -= count
            }
            let extra = buffer.withUnsafeMutableBytes { readFD(input, $0.baseAddress!, 1) }
            guard extra == 0, fchmod(output, 0o500) == 0 else { throw LinuxMihomoError.executable }
        } catch { throw LinuxMihomoError.executable }
    }

    private static func writePrivateFile(_ data: Data, to path: String) throws {
        let output = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw LinuxMihomoError.privateFiles }
        defer { closeFD(output) }
        guard fchmod(output, 0o600) == 0 else { throw LinuxMihomoError.privateFiles }
        try data.withUnsafeBytes { try writeAll(output, bytes: $0) }
    }

    private static func writeAll(_ descriptor: Int32, bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else { return }
        var offset = 0
        while offset < bytes.count {
            let count = write(descriptor, base.advanced(by: offset), bytes.count - offset)
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw LinuxMihomoError.privateFiles }
            offset += count
        }
    }

    private static func verifyBinary(_ engine: String, fingerprint: String, directory: String, signals: TerminationSignals) throws -> Int32? {
        let null = open("/dev/null", O_RDWR | O_CLOEXEC)
        guard null >= 0 else { throw LinuxMihomoError.digest }
        defer { closeFD(null) }
        let hashPath = directory + "/sha256"
        let output = open(hashPath, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard output >= 0 else { throw LinuxMihomoError.digest }
        defer { closeFD(output); _ = unlink(hashPath) }
        let child: Child
        do {
            child = try Child(executable: "/usr/bin/sha256sum", arguments: ["--", engine], home: directory, stdin: null, stdout: output, stderr: null)
        } catch { throw LinuxMihomoError.digest }
        defer { child.stop() }
        let deadline = DispatchTime.now() + .seconds(10)
        while child.isAlive() {
            if let interrupted = signals.poll(timeout: 35) { return interrupted }
            guard DispatchTime.now() < deadline else { throw LinuxMihomoError.digest }
        }
        guard child.rawStatus == 0, lseek(output, 0, SEEK_SET) == 0 else { throw LinuxMihomoError.digest }
        var bytes = [UInt8](repeating: 0, count: 1024)
        let count = bytes.withUnsafeMutableBytes { readFD(output, $0.baseAddress!, $0.count) }
        let expected = Array("\(fingerprint)  \(engine)\n".utf8)
        guard count == expected.count, bytes.prefix(count).elementsEqual(expected) else { throw LinuxMihomoError.digest }
        return nil
    }

    private static func childOwnsListeners(pid: pid_t, ports: Set<Int>) -> Bool {
        // /proc/<pid>/net/tcp describes the network namespace; only a socket
        // inode in /proc/<pid>/fd proves ownership by the verified process.
        let root = "/proc/\(pid)"
        guard let fds = try? FileManager.default.contentsOfDirectory(atPath: root + "/fd"),
              let handle = FileHandle(forReadingAtPath: root + "/net/tcp") else { return false }
        defer { try? handle.close() }
        var inodes: Set<Substring> = []
        for fd in fds {
            guard fd.utf8.allSatisfy({ (48...57).contains($0) }),
                  let path = try? FileManager.default.destinationOfSymbolicLink(atPath: root + "/fd/" + fd),
                  path.hasPrefix("socket:["), path.hasSuffix("]") else { continue }
            inodes.insert(path.dropFirst(8).dropLast())
        }
        guard !inodes.isEmpty else { return false }
        var bytes = Data()
        do {
            while let chunk = try handle.read(upToCount: 32_768), !chunk.isEmpty {
                guard bytes.count <= 4 * 1024 * 1024 - chunk.count else { return false }
                bytes.append(chunk)
            }
        } catch { return false }
        let loopback = inet_addr("127.0.0.1")
        var found: Set<Int> = []
        for line in String(decoding: bytes, as: UTF8.self).split(whereSeparator: \.isNewline) {
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 10, fields[3] == "0A", inodes.contains(fields[9]) else { continue }
            let local = fields[1].split(separator: ":", omittingEmptySubsequences: false)
            guard local.count == 2, let port = Int(local[1], radix: 16), ports.contains(port) else { continue }
            guard let address = UInt32(local[0], radix: 16), address == loopback else { return false }
            found.insert(port)
        }
        return found == ports
    }
}

private final class PortReservation {
    private var descriptor: Int32
    let port: Int

    init(_ requested: Int?) throws {
        guard requested.map({ (1...65535).contains($0) }) != false else { throw LinuxMihomoError.ports }
        #if canImport(Glibc)
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue | SOCK_CLOEXEC.rawValue), 0)
        #else
        let fd = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0)
        #endif
        guard fd >= 0 else { throw LinuxMihomoError.ports }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = UInt16(requested ?? 0).bigEndian
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        guard ok, address.sin_port != 0 else { closeFD(fd); throw LinuxMihomoError.ports }
        descriptor = fd
        port = Int(UInt16(bigEndian: address.sin_port))
    }

    func release() {
        guard descriptor >= 0 else { return }
        closeFD(descriptor)
        descriptor = -1
    }

    deinit { release() }
}

private final class TerminationSignals {
    private let descriptor: Int32
    private var original = sigset_t()

    init() throws {
        var mask = sigset_t()
        sigemptyset(&mask)
        sigaddset(&mask, SIGINT)
        sigaddset(&mask, SIGTERM)
        guard pthread_sigmask(SIG_BLOCK, &mask, &original) == 0 else { throw LinuxMihomoError.signals }
        // signalfd is Linux-specific and not declared in the Swift libc module
        // on every distribution. It is provided by glibc and musl.
        let fd = claySignalFD(-1, &mask, O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else {
            pthread_sigmask(SIG_SETMASK, &original, nil)
            throw LinuxMihomoError.signals
        }
        descriptor = fd
    }

    func poll(timeout: Int32) -> Int32? {
        var ready = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        var info = [UInt32](repeating: 0, count: 32) // Linux signalfd_siginfo begins with ssi_signo.
        guard pollFD(&ready, timeout) > 0, ready.revents & Int16(POLLIN) != 0,
              info.withUnsafeMutableBytes({ readFD(descriptor, $0.baseAddress!, $0.count) }) == 128,
              info[0] == UInt32(SIGINT) || info[0] == UInt32(SIGTERM) else { return nil }
        return 128 + Int32(info[0])
    }

    func close() {
        closeFD(descriptor)
        pthread_sigmask(SIG_SETMASK, &original, nil)
    }
}

@_silgen_name("signalfd")
private func claySignalFD(_ descriptor: Int32, _ mask: UnsafePointer<sigset_t>, _ flags: Int32) -> Int32

private final class Child {
    let pid: pid_t
    private(set) var rawStatus: Int32?

    init(executable: String, arguments: [String], home: String, stdin: Int32, stdout: Int32, stderr: Int32) throws {
        var actions = posix_spawn_file_actions_t(), attrs = posix_spawnattr_t()
        guard posix_spawn_file_actions_init(&actions) == 0 else { throw LinuxMihomoError.launch }
        defer { posix_spawn_file_actions_destroy(&actions) }
        guard posix_spawnattr_init(&attrs) == 0 else { throw LinuxMihomoError.launch }
        defer { posix_spawnattr_destroy(&attrs) }
        guard posix_spawn_file_actions_adddup2(&actions, stdin, STDIN_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stdout, STDOUT_FILENO) == 0,
              posix_spawn_file_actions_adddup2(&actions, stderr, STDERR_FILENO) == 0 else { throw LinuxMihomoError.launch }
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        guard posix_spawnattr_setsigmask(&attrs, &unblocked) == 0, posix_spawnattr_setpgroup(&attrs, 0) == 0,
              posix_spawnattr_setflags(&attrs, Int16(POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETPGROUP)) == 0 else { throw LinuxMihomoError.launch }
        var argv = ([executable] + arguments).map { $0.withCString { strdup($0) } }
        var envp = ["HOME=\(home)", "PATH=/usr/bin:/bin", "LANG=C", "TMPDIR=\(home)", "XDG_CACHE_HOME=\(home)", "XDG_CONFIG_HOME=\(home)"]
            .map { $0.withCString { strdup($0) } }
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        guard argv.allSatisfy({ $0 != nil }), envp.allSatisfy({ $0 != nil }) else { throw LinuxMihomoError.launch }
        argv.append(nil); envp.append(nil)
        var child: pid_t = 0
        guard posix_spawn(&child, executable, &actions, &attrs, &argv, &envp) == 0 else { throw LinuxMihomoError.launch }
        pid = child
    }

    func isAlive() -> Bool {
        guard rawStatus == nil else { return false }
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, WNOHANG) } while result < 0 && errno == EINTR
        if result == 0 { return true }
        rawStatus = result == pid ? status : -1
        return false
    }

    func stop() {
        guard isAlive() else { return }
        // This process owns the unreaped PID and its separate process group.
        _ = kill(-pid, SIGTERM)
        let deadline = DispatchTime.now() + .seconds(1)
        while DispatchTime.now() < deadline {
            if !isAlive() { return }
            _ = usleep(25_000)
        }
        _ = kill(-pid, SIGKILL)
        var status: Int32 = 0
        var result: pid_t
        repeat { result = waitpid(pid, &status, 0) } while result < 0 && errno == EINTR
        rawStatus = result == pid ? status : -1
    }
}
#endif
