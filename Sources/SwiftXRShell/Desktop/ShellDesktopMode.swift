import Foundation
import SwiftXR

@MainActor
final class ShellDesktopMode {
    private let session: XRSession
    private let swapchain: XRSwapchain
    private let onRequestHome: () -> Void

    private var setupTask: Task<Void, Never>?
    private var capture: DesktopCapture?
    private var renderer: DesktopRenderer?
    private(set) var isReady = false
    private(set) var failure: Error?

    init(
        session: XRSession,
        swapchain: XRSwapchain,
        onRequestHome: @escaping () -> Void
    ) {
        self.session = session
        self.swapchain = swapchain
        self.onRequestHome = onRequestHome
    }

    func activate() {
        failure = nil
        isReady = false

        setupTask?.cancel()
        setupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                print("[desktop] discovering primary display…")
                let capture = try await DesktopCapture.primaryDisplay(device: session.device)
                try Task.checkCancellation()

                let renderer = try DesktopRenderer(
                    device: session.device,
                    swapchain: swapchain,
                    capturedPixelSize: capture.pixelSize
                )
                try await capture.start()
                try Task.checkCancellation()

                self.capture = capture
                self.renderer = renderer
                self.isReady = true
                print(
                    "[desktop] capture started: " +
                    "\(capture.display.width)x\(capture.display.height)"
                )
                print("[desktop] Escape returns to SwiftXR Shell Home")
            } catch is CancellationError {
                return
            } catch {
                self.failure = error
                fputs("swiftxr-shell desktop: \(error)\n", stderr)
                self.onRequestHome()
            }
        }
    }

    func deactivate() {
        setupTask?.cancel()
        setupTask = nil
        isReady = false

        if let capture {
            Task { @MainActor in
                try? await capture.stop()
            }
        }
        capture = nil
        renderer = nil
    }

    func renderFrame() throws {
        let desktopFrame = try capture?.latestFrame()
        let renderer = self.renderer

        _ = try session.renderFrame(to: swapchain) { frame, texture, commandBuffer in
            if let renderer {
                try renderer.encode(
                    frame: frame,
                    swapchainTexture: texture,
                    desktopTexture: desktopFrame?.texture,
                    commandBuffer: commandBuffer
                )
            } else {
                try Self.clearFrame(
                    frame: frame,
                    texture: texture,
                    commandBuffer: commandBuffer
                )
            }
        }
    }

    private static func clearFrame(
        frame: XRFrame,
        texture: any MTLTexture,
        commandBuffer: any MTLCommandBuffer
    ) throws {
        guard frame.views.count >= 2 else { return }
        for eye in 0..<2 {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].slice = eye
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            pass.colorAttachments[0].clearColor = MTLClearColor(
                red: 0.012,
                green: 0.016,
                blue: 0.026,
                alpha: 1
            )
            guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else {
                throw DesktopRendererError.renderEncoderCreationFailed
            }
            encoder.endEncoding()
        }
    }
}
