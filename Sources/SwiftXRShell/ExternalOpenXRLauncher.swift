import AppKit
import Darwin
import Foundation
import SwiftXR

enum ExternalOpenXRLauncherError: Error, LocalizedError {
    case alreadyLaunching
    case applicationNotFound(String)
    case executableNotExecutable(String)
    case shellClientNotFound
    case openXRClientDidNotAppear(String)
    case launchedApplicationExited(String)
    case couldNotTerminate(String)

    var errorDescription: String? {
        switch self {
        case .alreadyLaunching:
            return "An external OpenXR application is already running"
        case let .applicationNotFound(path):
            return "External application was not found at \(path)"
        case let .executableNotExecutable(path):
            return "External application is not executable: \(path)"
        case .shellClientNotFound:
            return "Could not identify SwiftXR Shell in Monado's client list"
        case let .openXRClientDidNotAppear(title):
            return "\(title) launched, but no new Monado OpenXR client appeared"
        case let .launchedApplicationExited(title):
            return "\(title) exited before creating an OpenXR client"
        case let .couldNotTerminate(title):
            return "Could not terminate \(title)"
        }
    }
}

@MainActor
final class ExternalOpenXRLauncher {
    var onSwitchedToApplication: ((XRMonadoClient) -> Void)?
    var onReturnedToShell: (() -> Void)?
    var onError: ((Error) -> Void)?

    private var monado: XRMonadoRuntimeControl?
    private var monitorTask: Task<Void, Never>?
    private var terminationFallbackTask: Task<Void, Never>?

    private var baselineClientIDs = Set<UInt32>()
    private var shellClientID: UInt32?
    private var targetClientID: UInt32?
    private var launchDeadline = Date.distantPast
    private var currentApplication: ShellApplication?

    private var process: Process?
    private var runningApplication: NSRunningApplication?

    var isRunningExternalApplication: Bool {
        currentApplication != nil
    }

    var currentApplicationTitle: String? {
        currentApplication?.title
    }

    func launch(_ application: ShellApplication, external: ExternalOpenXRApplication) throws {
        guard currentApplication == nil else {
            throw ExternalOpenXRLauncherError.alreadyLaunching
        }

        let url = external.executableURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ExternalOpenXRLauncherError.applicationNotFound(url.path)
        }

        let monado = try monado ?? XRMonadoRuntimeControl()
        self.monado = monado

        let clients = try monado.refreshClients()
        guard let shellClient = clients.first(where: {
            $0.state.contains(.primaryApplication)
        }) ?? clients.first(where: {
            $0.name.caseInsensitiveCompare("SwiftXR Shell") == .orderedSame
        }) else {
            throw ExternalOpenXRLauncherError.shellClientNotFound
        }

        baselineClientIDs = Set(clients.map(\.id))
        shellClientID = shellClient.id
        targetClientID = nil
        currentApplication = application
        launchDeadline = Date().addingTimeInterval(30)

        if url.pathExtension.caseInsensitiveCompare("app") == .orderedSame {
            launchBundle(external)
        } else {
            try launchExecutable(external)
            startMonitoring()
        }
    }

    func terminateForegroundApplication() throws {
        let title = currentApplication?.title ?? "OpenXR application"

        if let process {
            if process.isRunning {
                process.terminate()
                scheduleForcedTermination()
            }
            return
        }

        if let runningApplication {
            if runningApplication.isTerminated {
                return
            }
            if runningApplication.terminate() {
                scheduleForcedTermination()
                return
            }
            if runningApplication.forceTerminate() {
                return
            }
        }

        throw ExternalOpenXRLauncherError.couldNotTerminate(title)
    }

    func shutdown() {
        monitorTask?.cancel()
        monitorTask = nil
        terminationFallbackTask?.cancel()
        terminationFallbackTask = nil
        clearLaunchState()
    }

    private func launchBundle(_ external: ExternalOpenXRApplication) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = external.arguments
        configuration.environment = mergedEnvironment(overrides: external.environment)
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = true

        NSWorkspace.shared.openApplication(
            at: external.executableURL,
            configuration: configuration
        ) { [weak self] runningApplication, error in
            Task { @MainActor in
                guard let self, self.currentApplication != nil else { return }

                if let error {
                    self.fail(error)
                    return
                }
                guard let runningApplication else {
                    self.fail(
                        ExternalOpenXRLauncherError.launchedApplicationExited(
                            self.currentApplication?.title ?? external.executableURL.lastPathComponent
                        )
                    )
                    return
                }

                self.runningApplication = runningApplication
                self.startMonitoring()
            }
        }
    }

    private func launchExecutable(_ external: ExternalOpenXRApplication) throws {
        let path = external.executableURL.path
        guard FileManager.default.isExecutableFile(atPath: path) else {
            throw ExternalOpenXRLauncherError.executableNotExecutable(path)
        }

        let process = Process()
        process.executableURL = external.executableURL
        process.arguments = external.arguments
        process.environment = mergedEnvironment(overrides: external.environment)
        process.currentDirectoryURL = external.executableURL.deletingLastPathComponent()
        try process.run()
        self.process = process
    }

    private func startMonitoring() {
        monitorTask?.cancel()
        monitorTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self, self.currentApplication != nil else { return }
                self.pollMonadoClients()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
        }
    }

    private func scheduleForcedTermination() {
        terminationFallbackTask?.cancel()
        terminationFallbackTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, !Task.isCancelled, self.currentApplication != nil else { return }

            if let process = self.process, process.isRunning {
                print("[shell] launched process ignored terminate; sending SIGKILL")
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }

            if let runningApplication = self.runningApplication,
               !runningApplication.isTerminated {
                print("[shell] launched application ignored terminate; force terminating")
                _ = runningApplication.forceTerminate()
            }
        }
    }

    private func pollMonadoClients() {
        guard
            let monado,
            let application = currentApplication,
            case let .external(external) = application.kind
        else { return }

        do {
            let clients = try monado.refreshClients()

            if let targetClientID {
                if !clients.contains(where: { $0.id == targetClientID }) {
                    try restoreShell(using: clients)
                }
                return
            }

            let candidates = clients.filter {
                !baselineClientIDs.contains($0.id) && !$0.state.contains(.sessionOverlay)
            }

            if let target = chooseTarget(
                from: candidates,
                expectedApplicationName: external.openXRApplicationName
            ) {
                try monado.setPrimary(clientID: target.id)
                try monado.setFocused(clientID: target.id)
                targetClientID = target.id
                print("[shell] handed HMD to Monado client \(target.id): \(target.name)")
                onSwitchedToApplication?(target)
                return
            }

            if launchedApplicationHasExited {
                throw ExternalOpenXRLauncherError.launchedApplicationExited(application.title)
            }

            if Date() >= launchDeadline {
                throw ExternalOpenXRLauncherError.openXRClientDidNotAppear(application.title)
            }
        } catch {
            fail(error)
        }
    }

    private func chooseTarget(
        from candidates: [XRMonadoClient],
        expectedApplicationName: String?
    ) -> XRMonadoClient? {
        guard !candidates.isEmpty else { return nil }

        if let expectedApplicationName, !expectedApplicationName.isEmpty {
            if let exact = candidates.first(where: {
                $0.name.caseInsensitiveCompare(expectedApplicationName) == .orderedSame
            }) {
                return exact
            }

            if let partial = candidates.first(where: {
                $0.name.localizedCaseInsensitiveContains(expectedApplicationName)
                    || expectedApplicationName.localizedCaseInsensitiveContains($0.name)
            }) {
                return partial
            }
        }

        return candidates.sorted { lhs, rhs in
            let lhsActive = lhs.state.contains(.sessionActive)
            let rhsActive = rhs.state.contains(.sessionActive)
            if lhsActive != rhsActive {
                return lhsActive && !rhsActive
            }
            return lhs.id < rhs.id
        }.first
    }

    private func restoreShell(using clients: [XRMonadoClient]) throws {
        guard let shellClientID else {
            throw ExternalOpenXRLauncherError.shellClientNotFound
        }
        guard clients.contains(where: { $0.id == shellClientID }) else {
            throw ExternalOpenXRLauncherError.shellClientNotFound
        }
        guard let monado else { return }

        try monado.setPrimary(clientID: shellClientID)
        try monado.setFocused(clientID: shellClientID)
        print("[shell] external OpenXR client exited; restored SwiftXR Shell")

        monitorTask?.cancel()
        monitorTask = nil
        terminationFallbackTask?.cancel()
        terminationFallbackTask = nil
        clearLaunchState()
        onReturnedToShell?()
    }

    private func fail(_ error: Error) {
        if let monado, let shellClientID {
            if let clients = try? monado.refreshClients(),
               clients.contains(where: { $0.id == shellClientID }) {
                try? monado.setPrimary(clientID: shellClientID)
                try? monado.setFocused(clientID: shellClientID)
            }
        }

        monitorTask?.cancel()
        monitorTask = nil
        terminationFallbackTask?.cancel()
        terminationFallbackTask = nil
        clearLaunchState()
        onError?(error)
    }

    private var launchedApplicationHasExited: Bool {
        if let process {
            return !process.isRunning
        }
        if let runningApplication {
            return runningApplication.isTerminated
        }
        return false
    }

    private func mergedEnvironment(overrides: [String: String]) -> [String: String] {
        ProcessInfo.processInfo.environment.merging(overrides) { _, override in override }
    }

    private func clearLaunchState() {
        baselineClientIDs.removeAll()
        shellClientID = nil
        targetClientID = nil
        currentApplication = nil
        process = nil
        runningApplication = nil
        launchDeadline = .distantPast
    }
}
