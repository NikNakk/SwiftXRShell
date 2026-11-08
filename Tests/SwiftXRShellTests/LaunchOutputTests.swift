import Foundation
import Testing
@testable import SwiftXRShell

struct LaunchOutputTests {
    @Test func failureDetailsRemainBoundedAndVisible() {
        let tail = LaunchOutputTail()
        tail.append(Data(repeating: 65, count: 100_000))
        tail.append(Data("\nAssetto Corsa: 32-bit ntdll.dll is unavailable\n".utf8))
        #expect(tail.summary.utf8.count <= 16_384)
        #expect(tail.summary.contains("32-bit ntdll.dll"))
        let error = ExternalOpenXRLauncherError.executableFailed(title: "Assetto Corsa", status: 1, detail: tail.summary)
        #expect(error.localizedDescription.contains("32-bit ntdll.dll"))
    }
}
