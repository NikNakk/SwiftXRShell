import Foundation
import SwiftXR

enum ExternalOpenXRActivityMonitorError: Error, LocalizedError {
    case shellClientNotFound

    var errorDescription: String? {
        switch self {
        case .shellClientNotFound:
            return "Could not identify SwiftXR Shell in Monado's client list"
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
    var onError: ((Error) -> Void)?

    private var monado: XRMonadoRuntimeControl?
    private var monitorTask: Task<Void, Never>?
    private var shellClientID: UInt32?
    private var foregroundClient: XRMonadoClient?
    private var reportedCurrentError = false

    var isPresentingExternalSession: Bool {
        foregroundClient != nil
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
        shellClientID = nil
        monado = nil
        reportedCurrentError = false
    }

    private func poll() {
        guard let monado else { return }

        do {
            let clients = try monado.refreshClients()
            reportedCurrentError = false

            if shellClientID == nil
                || !clients.contains(where: { $0.id == shellClientID }) {
                shellClientID = clients.first(where: {
                    $0.name.caseInsensitiveCompare("SwiftXR Shell") == .orderedSame
                })?.id
            }

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

            guard canTakeOver?() ?? true else { return }
            guard let shellClientID else { return }

            let candidates = clients.filter {
                $0.id != shellClientID
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
        guard
            let shellClientID,
            clients.contains(where: { $0.id == shellClientID })
        else {
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
