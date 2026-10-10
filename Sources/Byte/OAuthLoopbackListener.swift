import Foundation
import Network

/// Listen only on 127.0.0.1, using a free port and the same callback path on
/// every sign-in. Unrelated browser requests cannot consume the transaction.
@MainActor
final class OAuthLoopbackListener {
    var expectedState: String?
    private var listener: NWListener?
    private var redirectURI: URL?
    private var ready: CheckedContinuation<URL, Error>?
    private var callback: CheckedContinuation<URL, Error>?
    private var result: Result<URL, Error>?
    private var timeout: Task<Void, Never>?
    private var connections: [UUID: NWConnection] = [:]

    func start() async throws -> URL {
        try Task.checkCancellation()
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor [weak self] in self?.accept(connection) }
        }
        listener.stateUpdateHandler = { [weak self, weak listener] state in
            Task { @MainActor [weak self, weak listener] in
                guard let self, let listener else { return }
                switch state {
                case .ready:
                    guard let port = listener.port else {
                        self.complete(.failure(ChatGPTConnectionError("Couldn't start the sign-in callback.")))
                        return
                    }
                    let url = URL(string: "http://127.0.0.1:\(port.rawValue)/auth/callback")!
                    self.redirectURI = url
                    self.ready?.resume(returning: url)
                    self.ready = nil
                case .failed:
                    self.complete(.failure(ChatGPTConnectionError("Couldn't listen for sign-in. Try again.")))
                case .cancelled:
                    self.complete(.failure(CancellationError()))
                default: break
                }
            }
        }
        timeout = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 600_000_000_000) }
            catch { return }
            self?.complete(.failure(ChatGPTConnectionError("Sign-in timed out. Continue with ChatGPT again.")))
            self?.listener?.cancel()
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                ready = continuation
                listener.start(queue: .main)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func waitForCallback() async throws -> URL {
        try Task.checkCancellation()
        if let result { return try result.get() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { callback = $0 }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancel() }
        }
    }

    func cancel() {
        complete(.failure(CancellationError()))
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        for connection in connections.values { connection.cancel() }
        connections.removeAll()
    }

    private func complete(_ value: Result<URL, Error>) {
        guard result == nil else { return }
        result = value
        ready?.resume(with: value)
        ready = nil
        callback?.resume(with: value)
        callback = nil
    }

    private func accept(_ connection: NWConnection) {
        guard result == nil, connections.count < 16 else { connection.cancel(); return }
        let id = UUID()
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, id: id, accumulated: Data())
        Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 10_000_000_000) }
            catch { return }
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }

    private func receive(_ connection: NWConnection, id: UUID, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, done, error in
            Task { @MainActor [weak self] in
                guard let self, self.connections[id] != nil else { return }
                let received = accumulated + (data ?? Data())
                guard received.count <= 16_384, error == nil else {
                    self.connections.removeValue(forKey: id)?.cancel()
                    return
                }
                if let text = String(data: received, encoding: .utf8), text.contains("\r\n\r\n") {
                    self.handle(text, connection: connection, id: id)
                } else if done {
                    self.connections.removeValue(forKey: id)?.cancel()
                } else {
                    self.receive(connection, id: id, accumulated: received)
                }
            }
        }
    }

    private func handle(_ request: String, connection: NWConnection, id: UUID) {
        guard let redirectURI else { reply(400, connection: connection, id: id); return }
        let lines = request.components(separatedBy: "\r\n")
        let parts = (lines.first ?? "").split(separator: " ")
        let host = lines.dropFirst().first { $0.lowercased().hasPrefix("host:") }?
            .dropFirst(5).trimmingCharacters(in: .whitespaces)
        guard parts.count == 3, parts[0] == "GET",
              host == "127.0.0.1:\(redirectURI.port!)",
              parts[1].hasPrefix("/"), !parts[1].hasPrefix("//"),
              let url = URL(string: String(parts[1]), relativeTo: redirectURI)?.absoluteURL,
              url.path == "/auth/callback",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems,
              items.filter({ $0.name == "state" }).count == 1,
              let state = expectedState, items.first(where: { $0.name == "state" })?.value == state,
              result == nil else { reply(400, connection: connection, id: id); return }
        reply(200, connection: connection, id: id)
        complete(.success(url))
        timeout?.cancel()
        listener?.cancel()
    }

    private func reply(_ status: Int, connection: NWConnection, id: UUID) {
        let message = status == 200
            ? "Return to Byte to finish connecting. You can close this tab."
            : "This sign-in request is invalid. Return to Byte and try again."
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(status) \(status == 200 ? "OK" : "Bad Request")\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            Task { @MainActor [weak self] in self?.connections.removeValue(forKey: id) }
        })
    }
}
