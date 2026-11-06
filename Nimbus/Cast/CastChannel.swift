import Foundation
import Network

nonisolated final class CastChannel: @unchecked Sendable {
    struct Closed: Error {}

    let messages: AsyncStream<CastMessage>
    private let continuation: AsyncStream<CastMessage>.Continuation
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "io.github.dearonski.Nimbus.cast")
    // Touched only on `queue`.
    private var buffer: [UInt8] = []
    private var opening: CheckedContinuation<Void, any Error>?

    init(endpoint: NWEndpoint) {
        let tls = NWProtocolTLS.Options()
        // Every Cast device presents a self-signed certificate; the TLS is for the wire, not for trust.
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, _, complete in complete(true) }, queue)
        let tcp = NWProtocolTCP.Options()
        tcp.connectionTimeout = 8
        connection = NWConnection(to: endpoint, using: NWParameters(tls: tls, tcp: tcp))
        (messages, continuation) = AsyncStream.makeStream(of: CastMessage.self)
    }

    func open() async throws {
        try await withCheckedThrowingContinuation { (opening: CheckedContinuation<Void, any Error>) in
            queue.async { [self] in
                self.opening = opening
                connection.stateUpdateHandler = { [weak self] state in self?.changed(to: state) }
                connection.start(queue: queue)
            }
        }
    }

    func send(_ message: CastMessage) {
        connection.send(content: message.framed(), completion: .contentProcessed { _ in })
    }

    func close() {
        queue.async { [self] in
            connection.cancel()
            finish(with: Closed())
        }
    }

    private func changed(to state: NWConnection.State) {
        switch state {
        case .ready:
            opening?.resume()
            opening = nil
            receive()
        case .failed(let error):
            finish(with: error)
        case .waiting(let error):
            // A device that went away leaves the connection waiting forever rather than failing.
            if opening != nil {
                connection.cancel()
                finish(with: error)
            }
        case .cancelled:
            finish(with: Closed())
        default:
            break
        }
    }

    private func finish(with error: any Error) {
        opening?.resume(throwing: error)
        opening = nil
        continuation.finish()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { buffer.append(contentsOf: data) }
            drainFrames()
            if isComplete || error != nil {
                connection.cancel()
                finish(with: error ?? Closed())
            } else {
                receive()
            }
        }
    }

    private func drainFrames() {
        var start = 0
        while buffer.count - start >= 4 {
            let length = buffer[start..<start + 4].reduce(0) { $0 << 8 | Int($1) }
            guard buffer.count - start - 4 >= length else { break }
            let body = buffer[(start + 4)..<(start + 4 + length)]
            if let message = CastMessage(body: body) { continuation.yield(message) }
            start += 4 + length
        }
        if start > 0 { buffer.removeFirst(start) }
    }
}
