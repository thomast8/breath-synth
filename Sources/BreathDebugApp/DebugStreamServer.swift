import Foundation
import Network

/// A tiny loopback Server-Sent-Events server so an external observer can watch the debug session
/// live: `curl -N http://127.0.0.1:<port>/`. Every connected client receives each event as an SSE
/// `data: <json>` line. Bound to 127.0.0.1 only.
///
/// `@unchecked Sendable` is sound because all NWListener/NWConnection state is confined to the
/// private serial `queue` (every entry point dispatches onto it before touching that state).
final class DebugStreamServer: @unchecked Sendable {
    let port: UInt16
    private let queue = DispatchQueue(label: "com.breathsynth.DebugStreamServer")
    private var listener: NWListener?
    private var clients: [ObjectIdentifier: NWConnection] = [:]
    private(set) var lastError: String?

    init(port: UInt16) {
        self.port = port
    }

    func start() {
        queue.async { self.startLocked() }
    }

    private func startLocked() {
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            lastError = "invalid port \(port)"
            return
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredInterfaceType = .loopback
        do {
            let listener = try NWListener(using: params, on: nwPort)
            listener.stateUpdateHandler = { [weak self] state in
                // Surface a bind failure (e.g. port already in use) instead of silently never serving.
                if case .failed(let error) = state { self?.lastError = "listener failed: \(error)" }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            lastError = "\(error)"
        }
    }

    private func accept(_ connection: NWConnection) {
        // Bound concurrent observers so a pile of stuck clients can't grow unboundedly (loopback only).
        guard clients.count < 16 else {
            connection.cancel()
            return
        }
        clients[ObjectIdentifier(connection)] = connection
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                self?.clients[ObjectIdentifier(connection)] = nil
            default:
                break
            }
        }
        connection.start(queue: queue)

        // Minimal SSE response header; we don't parse the request, any path streams events.
        // No Access-Control-Allow-Origin: this is a loopback dev stream; we don't want arbitrary
        // local web pages reading the session cross-origin. `curl`/EventSource on the same origin
        // still work.
        let header = """
        HTTP/1.1 200 OK\r
        Content-Type: text/event-stream\r
        Cache-Control: no-cache\r
        Connection: keep-alive\r
        \r

        """
        connection.send(content: Data(header.utf8), completion: .contentProcessed { _ in })
        // Greet on connect so a freshly-attached client immediately sees a line (proves the pipe;
        // SSE otherwise only delivers events that occur after connection).
        let hello = "data: {\"event\":\"stream_open\",\"port\":\(port)}\n\n"
        connection.send(content: Data(hello.utf8), completion: .contentProcessed { _ in })
        drain(connection) // read and discard the incoming HTTP request
    }

    private func drain(_ connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] _, _, isComplete, error in
            // Remote closed (curl exited) or errored: cancel so the socket/FD is released. Without
            // this the server-side connection lingers in CLOSE_WAIT and leaks a descriptor per client.
            if isComplete || error != nil {
                connection.cancel() // → .cancelled state handler removes it from `clients`
                return
            }
            self?.drain(connection)
        }
    }

    /// Broadcast one already-encoded JSON line to all connected clients as an SSE event.
    func broadcast(_ jsonLine: String) {
        queue.async {
            guard !self.clients.isEmpty else { return }
            let payload = Data("data: \(jsonLine)\n\n".utf8)
            for connection in self.clients.values {
                connection.send(content: payload, completion: .contentProcessed { _ in })
            }
        }
    }

    func stop() {
        queue.async {
            self.listener?.cancel()
            self.listener = nil
            for connection in self.clients.values { connection.cancel() }
            self.clients.removeAll()
        }
    }
}
