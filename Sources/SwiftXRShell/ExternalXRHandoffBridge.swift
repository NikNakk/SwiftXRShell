import Foundation
@preconcurrency import Network

enum ExternalXRHandoffBridgeError: Error, LocalizedError {
    case shellUnavailable
    case shellBusy
    case invalidRequest

    var errorDescription: String? {
        switch self {
        case .shellUnavailable:
            return "SwiftXR Shell is unavailable"
        case .shellBusy:
            return "SwiftXR Shell cannot yield XR from its current mode"
        case .invalidRequest:
            return "Invalid cooperative OpenXR handoff request"
        }
    }
}

/// Tiny loopback-only HTTP bridge used by browser integrations to coordinate
/// ownership of an exclusive OpenXR runtime.
///
/// OpenXR itself has no cross-application API for one client to ask another
/// client to relinquish a session. Monado has runtime-specific controls for
/// this, but other runtimes do not. This bridge therefore coordinates the
/// transition outside OpenXR while keeping the actual runtime generic.
final class ExternalXRHandoffBridge: @unchecked Sendable {
    enum Command {
        case prepare
        case resume
    }

    typealias Completion = (Result<String, Error>) -> Void
    typealias Handler = (Command, @escaping Completion) -> Void

    static let port: UInt16 = 49375

    private let handler: Handler
    private var listener: NWListener?

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    func start() throws {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: Self.port) else {
            throw ExternalXRHandoffBridgeError.invalidRequest
        }

        let listener = try NWListener(using: .tcp, on: port)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                print(
                    "[handoff] browser bridge listening on 127.0.0.1:"
                        + String(Self.port)
                )
            case let .failed(error):
                fputs("[handoff] browser bridge failed: \(error)\n", stderr)
            default:
                break
            }
        }
        listener.start(queue: .main)
        self.listener = listener
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .main)
        connection.receive(
            minimumIncompleteLength: 1,
            maximumLength: 16 * 1024
        ) { [weak self, weak connection] data, _, _, error in
            guard let self, let connection else { return }

            if let error {
                self.send(
                    connection,
                    status: 500,
                    body: "receive failed: \(error)"
                )
                return
            }

            guard let data,
                  let request = String(data: data, encoding: .utf8)
            else {
                self.send(connection, status: 400, body: "invalid request")
                return
            }

            self.handle(request, connection: connection)
        }
    }

    private func handle(_ request: String, connection: NWConnection) {
        let lowercased = request.lowercased()

        // A normal webpage cannot issue this custom-header request to a
        // loopback origin without passing CORS preflight. The extension
        // background worker has explicit loopback host permission.
        guard lowercased.contains("\r\nx-swiftxr-handoff: 1\r\n") else {
            send(connection, status: 403, body: "missing handoff header")
            return
        }

        let command: Command
        if request.hasPrefix("POST /prepare ") {
            command = .prepare
        } else if request.hasPrefix("POST /resume ") {
            command = .resume
        } else {
            send(connection, status: 404, body: "unknown handoff command")
            return
        }

        print("[handoff] browser request: \(request.split(separator: " ").prefix(2).joined(separator: " "))")
        handler(command) { [weak self, weak connection] result in
            guard let self, let connection else { return }
            DispatchQueue.main.async {
                switch result {
                case let .success(body):
                    print("[handoff] browser request completed: \(body)")
                    self.send(connection, status: 200, body: body)
                case let .failure(error):
                    self.send(
                        connection,
                        status: 409,
                        body: error.localizedDescription
                    )
                }
            }
        }
    }

    private func send(_ connection: NWConnection, status: Int, body: String) {
        let reason: String
        switch status {
        case 200: reason = "OK"
        case 400: reason = "Bad Request"
        case 403: reason = "Forbidden"
        case 404: reason = "Not Found"
        case 409: reason = "Conflict"
        default: reason = "Internal Server Error"
        }

        let bodyData = Data(body.utf8)
        let header =
            "HTTP/1.1 \(status) \(reason)\r\n"
            + "Content-Type: text/plain; charset=utf-8\r\n"
            + "Content-Length: \(bodyData.count)\r\n"
            + "Access-Control-Allow-Origin: *\r\n"
            + "Connection: close\r\n\r\n"

        var response = Data(header.utf8)
        response.append(bodyData)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            }
        )
    }
}
