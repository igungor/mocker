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

@Suite("ComposeOrchestrator.tearDown Tests")
struct ComposeTearDownTests {

    private actor Calls {
        var log: [String] = []
        func add(_ call: String) { log.append(call) }
    }

    private func container(_ name: String, _ state: ContainerState) -> ContainerInfo {
        ContainerInfo(id: name, name: name, image: "alpine", state: state, status: "", created: Date())
    }

    @Test("stops a running container, then removes it")
    func running() async throws {
        let calls = Calls()

        _ = try await ComposeOrchestrator.tearDown(
            [container("app-web-1", .running)],
            stop: { await calls.add("stop \($0.name)") },
            remove: { await calls.add("remove \($0.name) force=\($1)") }
        )

        #expect(await calls.log == ["stop app-web-1", "remove app-web-1 force=true"])
    }

    @Test("removes a container listed as stopped by force, since an interrupted up can have started it since")
    func listedStopped() async throws {
        let calls = Calls()

        _ = try await ComposeOrchestrator.tearDown(
            [container("app-db-1", .stopped)],
            stop: { await calls.add("stop \($0.name)") },
            remove: { await calls.add("remove \($0.name) force=\($1)") }
        )

        #expect(await calls.log == ["remove app-db-1 force=true"])
    }
}
