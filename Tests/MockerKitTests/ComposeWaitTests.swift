import Foundation
import Testing
@testable import MockerKit

@Suite("ComposeOrchestrator.checkAll Tests")
struct ComposeWaitTests {

    private struct CheckFailed: Error {}

    @Test("checks every service at the same time")
    func concurrently() async throws {
        let start = Date()

        try await ComposeOrchestrator.checkAll(["a", "b", "c", "d", "e"]) { _ in
            try await Task.sleep(for: .seconds(1))
        }

        // One after the other the checks take 5s. A busy CI runner delays checks that
        // run at once by up to a second, so the limit leaves room for that.
        #expect(Date().timeIntervalSince(start) < 3.0)
    }

    @Test("throws when one check fails, without waiting for the slow ones")
    func firstError() async throws {
        let start = Date()

        await #expect(throws: CheckFailed.self) {
            try await ComposeOrchestrator.checkAll(["slow", "broken"]) { name in
                if name == "broken" { throw CheckFailed() }
                try await Task.sleep(for: .seconds(10))
            }
        }
        #expect(Date().timeIntervalSince(start) < 2.0)
    }
}
