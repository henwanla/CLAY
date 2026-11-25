#if os(macOS)
import Foundation
import Network

/// Hosts only the current PAC script. The random URL avoids reusing a stale
/// PAC cache entry and the socket is bound to IPv4 loopback, not all interfaces.
public final class PACServer: Sendable {
    public let url: URL
    private let service: PACListener

    private init(url: URL, service: PACListener) {
        self.url = url
        self.service = service
    }

    public static func start(script: String) async throws -> PACServer {
        let service = try PACListener(script: script)
        let url = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { service.start($0) }
        } onCancel: {
            service.stop()
        }
        if Task.isCancelled {
            service.stop()
            throw CancellationError()
        }
        return PACServer(url: url, service: service)
    }

    public func stop() { service.stop() }
    deinit { service.stop() }
}

// Mutable listener and connection state lives exclusively on the serial queue.
private final class PACListener: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.clay.pac")
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let listener: NWListener
    private let body: Data
    private let path = "/\(UUID().uuidString.lowercased()).pac"
    private var clients: [UUID: Client] = [:]
    private var ready: CheckedContinuation<URL, any Error>?
    private var stopped = false
    private static let headerEnd = Data("\r\n\r\n".utf8)
    private static let headerLimit = 8192

    private final class Client {
        let connection: NWConnection
        var request = Data()
        init(_ connection: NWConnection) { self.connection = connection }
    }

    init(script: String) throws {
        body = Data(script.utf8)
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        queue.setSpecific(key: queueKey, value: 1)
    }

    func start(_ continuation: CheckedContinuation<URL, any Error>) {
        queue.async {
            guard !self.stopped else { continuation.resume(throwing: CancellationError()); return }
            self.ready = continuation
            self.listener.stateUpdateHandler = { [weak self] state in self?.stateChanged(state) }
            self.listener.newConnectionHandler = { [weak self] connection in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
            self.listener.start(queue: self.queue)
            self.queue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in
                guard let self, self.ready != nil else { return }
                self.close(error: PACError.cannotServe)
            }
        }
    }

    private func stateChanged(_ state: NWListener.State) {
        guard !stopped else { return }
        switch state {
        case .ready:
            guard let port = listener.port, port != .any,
                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(path)") else { close(error: PACError.cannotServe); return }
            ready?.resume(returning: url)
            ready = nil
        case .failed, .waiting:
            close(error: PACError.cannotServe)
        case .cancelled:
            close(error: CancellationError())
        default: break
        }
    }

    func stop() {
        if DispatchQueue.getSpecific(key: queueKey) != nil { close(error: CancellationError()) }
        else { queue.sync { close(error: CancellationError()) } }
    }

    private func close(error: any Error) {
        guard !stopped else { return }
        stopped = true
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        clients.values.forEach { $0.connection.cancel() }
        clients.removeAll()
        ready?.resume(throwing: error)
        ready = nil
    }

    private func accept(_ connection: NWConnection) {
        guard !stopped, clients.count < 32 else { connection.cancel(); return }
        let id = UUID()
        clients[id] = Client(connection)
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.finish(id)
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in self?.finish(id) }
        receive(id)
    }

    private func receive(_ id: UUID) {
        clients[id]?.connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, complete, error in
            guard let self, let client = self.clients[id] else { return }
            if let data { client.request.append(data) }
            if let end = client.request.range(of: Self.headerEnd), end.upperBound <= Self.headerLimit {
                self.respond(id, request: client.request[..<end.lowerBound])
            } else if client.request.count >= Self.headerLimit {
                self.send(id, status: "431 Request Header Fields Too Large")
            } else if complete || error != nil {
                self.finish(id)
            } else {
                self.receive(id)
            }
        }
    }

    private func respond(_ id: UUID, request: Data.SubSequence) {
        guard let line = String(bytes: request.prefix(while: { $0 != 13 && $0 != 10 }), encoding: .ascii) else {
            send(id, status: "400 Bad Request"); return
        }
        let fields = line.split(separator: " ", omittingEmptySubsequences: false)
        guard fields.count == 3, fields[2] == "HTTP/1.1" || fields[2] == "HTTP/1.0" else {
            send(id, status: "400 Bad Request"); return
        }
        // No query, absolute-form targets, traversal, or other resources.
        guard fields[1] == path else { send(id, status: "404 Not Found"); return }
        guard fields[0] == "GET" || fields[0] == "HEAD" else {
            send(id, status: "405 Method Not Allowed", extra: "Allow: GET, HEAD\r\n"); return
        }
        send(id, status: "200 OK", script: true, head: fields[0] == "HEAD")
    }

    private func send(_ id: UUID, status: String, script: Bool = false, head: Bool = false, extra: String = "") {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(script ? "application/x-ns-proxy-autoconfig" : "text/plain")\r\nContent-Length: \(script ? body.count : 0)\r\nCache-Control: no-store\r\nConnection: close\r\n\(extra)\r\n"
        var response = Data(header.utf8)
        if script && !head { response.append(body) }
        clients[id]?.connection.send(content: response, completion: .contentProcessed { [weak self] _ in self?.finish(id) })
    }

    private func finish(_ id: UUID) {
        guard let client = clients.removeValue(forKey: id) else { return }
        client.connection.stateUpdateHandler = nil
        client.connection.cancel()
    }
}
#endif
