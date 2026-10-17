import Foundation
import Testing
@testable import MockerKit

@Suite("ComposeOrchestrator.stopListed Tests")
struct ComposeDownTests {

    private struct StopFailed: Error {}

    @Test("stops a running container")
    func stops() async throws {
        let stopped = try await ComposeOrchestrator.stopListed {}

        #expect(stopped)
    }

    @Test("goes on when the container exited on its own since it was listed")
    func alreadyExited() async throws {
        let stopped = try await ComposeOrchestrator.stopListed {
            throw MockerError.containerNotRunning("app-builder-1")
        }

        #expect(!stopped)
    }

    @Test("still fails when the container can't be stopped")
    func otherErrors() async {
        await #expect(throws: StopFailed.self) {
            _ = try await ComposeOrchestrator.stopListed { throw StopFailed() }
        }
    }
}
