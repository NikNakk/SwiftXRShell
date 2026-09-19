import Foundation
import SwiftXR

enum ExternalOpenXRActivityMonitorError: Error, LocalizedError {
    case shellClientNotFound
    case noSuppressedSession
    case suppressedSessionNotActive(String)

    var errorDescription: String? {
        switch self {
        case .shellClientNotFound:
            return "Could not identify SwiftXR Shell in Monado's client list"
        case .noSuppressedSession:
            return "There is no suspended external OpenXR session to resume"
        case let .suppressedSessionNotActive(name):
            return "\(name) no longer has an active OpenXR session"
        }
    }
}

/// Watches Monado for immersive OpenXR sessions that were started independently
/// of SwiftXR Shell (for example Chromium entering WebXR).
///
/// A connected client alone is not enough to trigger a handoff. Desktop
/// browsers may keep an OpenXR instance connected for runtime/device polling
/// while no immersive session exists. We therefore wait for sessionActive.
@MainActor
final class ExternalOpenXRActivityMonitor {
    var canTakeOver: (() -> Bool)?
    var onExternalSessionBecameActive: ((XRMonadoClient) -> Void)?
    var onExternalSessionEnded: ((XRMonadoClient) -> Void)?
    var onSuppressedExternalSessionEnded: ((XRMonadoClient) -> Void)?
    var onError: ((Error) -> Void)?

    private var monado: XRMonadoRuntimeControl?
    private var monitorTask: Task<Void, Never>?
    private var shellClientID: UInt32?
    private var foregroundClient: XRMonadoClient?
    private var suppressedClient: XRMonadoClient?
    private var reportedCurrentError = false

    var isPresentingExternalSession: Bool {
        foregroundClient != nil
    }

    var suppressedSession: XRMonadoClient? {
        suppressedClient
    }

    func start() {
        shutdown()

        do {
            monado = try XRMonadoRuntimeControl()
        } catch {
            onError?(error)
            return
        }

        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.poll()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    func shutdown() {
        monitorTask?.cancel()
        monitorTask = nil
        foregroundClient = nil
        suppressedClient = nil
        shellClientID = nil
        monado = nil
        reportedCurrentError = false
    }

    /// Give presentation back to SwiftXR Shell without ending the external
    /// session. The external client is suppressed from automatic takeover until
    /// it becomes inactive or is explicitly resumed.
    @discardableResult
    func returnForegroundSessionToShell() throws -> XRMonadoClient {
        guard let monado else {
            throw ExternalOpenXRActivityMonitorError.shellClientNotFound
        }

        let clients = try monado.refreshClients()
        try updateShellClientID(using: clients)

        guard
            let foregroundClient,
            let current = clients.first(where: { $0.id == foregroundClient.id }),
            current.state.contains(.sessionActive)
        else {
            throw ExternalOpenXRActivityMonitorError.noSuppressedSession
        }
        guard let shellClientID else {
            throw ExternalOpenXRActivityMonitorError.shellClientNotFound
        }

        try monado.setPrimary(clientID: shellClientID)
        try monado.setFocused(clientID: shellClientID)

        self.foregroundClient = nil
        suppressedClient = current

        print(
            "[shell] returned HMD to SwiftXR Shell while keeping external session active: "
                + "\(current.id): \(current.name)"
        )
        return current
    }

    /// Restore a previously suppressed external session as primary/focused.
    @discardableResult
    func resumeSuppressedSession() throws -> XRMonadoClient {
        guard let monado else {
            throw ExternalOpenXRActivityMonitorError.noSuppressedSession
        }
        guard let suppressedClient else {
            throw ExternalOpenXRActivityMonitorError.noSuppressedSession
        }

        let clients = try monado.refreshClients()
        guard
            let current = clients.first(where: { $0.id == suppressedClient.id }),
            current.state.contains(.sessionActive)
        else {
            self.suppressedClient = nil
            throw ExternalOpenXRActivityMonitorError.suppressedSessionNotActive(
                suppressedClient.name
            )
        }

        try monado.setPrimary(clientID: current.id)
        try monado.setFocused(clientID: current.id)

        self.suppressedClient = nil
        foregroundClient = current

        print(
            "[shell] resumed suppressed external OpenXR session: "
                + "\(current.id): \(current.name)"
        )
        onExternalSessionBecameActive?(current)
        return current
    }

    private func poll() {
        guard let monado else { return }

        do {
            let clients = try monado.refreshClients()
            reportedCurrentError = false
            try updateShellClientID(using: clients)

            if let foregroundClient {
                guard let current = clients.first(where: { $0.id == foregroundClient.id }),
                      current.state.contains(.sessionActive)
                else {
                    try restoreShell(using: clients)
                    return
                }

                self.foregroundClient = current
                return
            }

            if let suppressedClient {
                if let current = clients.first(where: { $0.id == suppressedClient.id }),
                   current.state.contains(.sessionActive) {
                    self.suppressedClient = current
                } else {
                    self.suppressedClient = nil
                    print(
                        "[shell] suppressed external OpenXR session ended: "
                            + suppressedClient.name
                    )
                    onSuppressedExternalSessionEnded?(suppressedClient)
                }
            }

            guard canTakeOver?() ?? true else { return }
            guard let shellClientID else { return }
            let suppressedID = suppressedClient?.id

            let candidates = clients.filter {
                $0.id != shellClientID
                    && $0.id != suppressedID
                    && !$0.state.contains(.sessionOverlay)
                    && $0.state.contains(.sessionActive)
            }

            guard let target = chooseTarget(from: candidates) else { return }

            try monado.setPrimary(clientID: target.id)
            try monado.setFocused(clientID: target.id)
            foregroundClient = target

            print(
                "[shell] observed active external OpenXR session; handed HMD to "
                    + "\(target.id): \(target.name)"
            )
            onExternalSessionBecameActive?(target)
        } catch {
            reportOnce(error)
        }
    }

    private func updateShellClientID(using clients: [XRMonadoClient]) throws {
        if shellClientID == nil
            || !clients.contains(where: { $0.id == shellClientID }) {
            shellClientID = clients.first(where: {
                $0.name.caseInsensitiveCompare("SwiftXR Shell") == .orderedSame
            })?.id
        }

        guard shellClientID != nil else {
            throw ExternalOpenXRActivityMonitorError.shellClientNotFound
        }
    }

    private func chooseTarget(from candidates: [XRMonadoClient]) -> XRMonadoClient? {
        candidates.sorted { lhs, rhs in
            let lhsScore = priorityScore(lhs)
            let rhsScore = priorityScore(rhs)
            if lhsScore != rhsScore {
                return lhsScore > rhsScore
            }
            return lhs.id < rhs.id
        }.first
    }

    private func priorityScore(_ client: XRMonadoClient) -> Int {
        var score = 0
        if client.state.contains(.primaryApplication) { score += 4 }
        if client.state.contains(.sessionFocused) { score += 2 }
        if client.state.contains(.sessionVisible) { score += 1 }
        return score
    }

    private func restoreShell(using clients: [XRMonadoClient]) throws {
        try updateShellClientID(using: clients)
        guard let shellClientID else {
            throw ExternalOpenXRActivityMonitorError.shellClientNotFound
        }
        guard let monado, let endedClient = foregroundClient else { return }

        try monado.setPrimary(clientID: shellClientID)
        try monado.setFocused(clientID: shellClientID)
        foregroundClient = nil

        print(
            "[shell] external OpenXR session ended; restored SwiftXR Shell "
                + "(\(endedClient.name))"
        )
        onExternalSessionEnded?(endedClient)
    }

    private func reportOnce(_ error: Error) {
        guard !reportedCurrentError else { return }
        reportedCurrentError = true
        onError?(error)
    }
}
