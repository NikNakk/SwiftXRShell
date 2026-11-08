import Foundation

@MainActor
protocol ShellBrowserPresentation: AnyObject {
    var status: String { get }
    var onStatusChanged: (() -> Void)? { get set }
    func activate()
    func deactivate()
    func renderFrame() throws
}
