import Foundation
import Network

enum LabProbe {
    static func run(for target: LabContract.Target) async -> Bool {
        // The fixture marker must never be sent to a user-entered endpoint.
        guard target.isDemo, let port = NWEndpoint.Port(rawValue: target.port) else { return false }
        return await withCheckedContinuation { continuation in
            Attempt(address: target.address, port: port, completion: continuation).start()
        }
    }

    // NWConnection delegates all callbacks to this serial queue. The deadline
    // uses the same queue, so the continuation is resumed once.
    private final class Attempt: @unchecked Sendable {
        private let queue = DispatchQueue(label: "app.clay.lab.probe")
        private let connection: NWConnection
        private var completion: CheckedContinuation<Bool, Never>?
        private var sent = false

        init(address: String, port: NWEndpoint.Port, completion: CheckedContinuation<Bool, Never>) {
            connection = NWConnection(host: NWEndpoint.Host(address), port: port, using: .tcp)
            self.completion = completion
        }

        func start() {
            connection.stateUpdateHandler = { [self] state in
                switch state {
                case .ready where !sent:
                    sent = true
                    connection.send(content: LabContract.probe, completion: .contentProcessed { [self] error in
                        guard error == nil else { finish(false); return }
                        let size = LabContract.response.count
                        connection.receive(minimumIncompleteLength: size, maximumLength: size) { [self] bytes, _, _, error in
                            finish(error == nil && bytes == LabContract.response)
                        }
                    })
                case .failed, .cancelled:
                    finish(false)
                default:
                    break
                }
            }
            queue.asyncAfter(deadline: .now() + .seconds(5)) { [self] in finish(false) }
            connection.start(queue: queue)
        }

        private func finish(_ passed: Bool) {
            guard let completion else { return }
            self.completion = nil
            connection.stateUpdateHandler = nil
            connection.cancel()
            completion.resume(returning: passed)
        }
    }
}
