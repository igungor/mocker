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

    private struct StopFailed: Error {}

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

    @Test("stops a container only after the containers that depend on it have stopped")
    func dependentsFirst() async throws {
        let calls = Calls()

        _ = try await ComposeOrchestrator.tearDown(
            [container("app-db-1", .running), container("app-web-1", .running)],
            dependents: ["app-db-1": ["app-web-1"]],
            stop: { info in
                if info.name == "app-web-1" { try await Task.sleep(for: .milliseconds(200)) }
                await calls.add("stop \(info.name)")
            },
            remove: { info, _ in await calls.add("remove \(info.name)") }
        )

        let log = await calls.log
        let stopWeb = try #require(log.firstIndex(of: "stop app-web-1"))
        let stopDB = try #require(log.firstIndex(of: "stop app-db-1"))
        let removeDB = try #require(log.firstIndex(of: "remove app-db-1"))
        #expect(stopWeb < stopDB)
        #expect(stopDB < removeDB)
    }

    @Test("doesn't wait for a dependent's removal to stop its dependency")
    func removalOverlaps() async throws {
        let calls = Calls()

        _ = try await ComposeOrchestrator.tearDown(
            [container("app-db-1", .running), container("app-web-1", .running)],
            dependents: ["app-db-1": ["app-web-1"]],
            stop: { info in await calls.add("stop \(info.name)") },
            remove: { info, _ in
                if info.name == "app-web-1" { try await Task.sleep(for: .milliseconds(200)) }
                await calls.add("remove \(info.name)")
            }
        )

        let log = await calls.log
        let stopDB = try #require(log.firstIndex(of: "stop app-db-1"))
        let removeWeb = try #require(log.firstIndex(of: "remove app-web-1"))
        #expect(stopDB < removeWeb)
    }

    @Test("tears independent containers down at the same time")
    func parallel() async throws {
        let start = Date()

        _ = try await ComposeOrchestrator.tearDown(
            [container("app-web-1", .running), container("app-worker-1", .running)],
            stop: { _ in try await Task.sleep(for: .milliseconds(300)) },
            remove: { _, _ in }
        )

        #expect(Date().timeIntervalSince(start) < 0.55)
    }

    @Test("tears every container down before it throws a failure")
    func failure() async {
        let calls = Calls()

        await #expect(throws: StopFailed.self) {
            _ = try await ComposeOrchestrator.tearDown(
                [container("app-web-1", .running), container("app-db-1", .running)],
                dependents: ["app-db-1": ["app-web-1"]],
                stop: { info in
                    if info.name == "app-web-1" { throw StopFailed() }
                },
                remove: { info, _ in await calls.add("remove \(info.name)") }
            )
        }

        #expect(await calls.log == ["remove app-db-1"])
    }

    @Test("finds the containers of the services that depend on a container's service")
    func dependents() throws {
        let composeFile = try ComposeFile.parse("""
            services:
              db:
                image: mysql
              cache:
                image: valkey
              web:
                image: nginx
                depends_on: [db, cache]
              worker:
                image: alpine
                depends_on: [db]
            """)
        let containers = ["db", "cache", "web", "worker"].map {
            ContainerInfo(id: $0, name: "app-\($0)-1", image: "", state: .running, status: "", created: Date(),
                          labels: ["com.mocker.compose.service": $0])
        }

        let dependents = ComposeOrchestrator.dependents(of: containers, composeFile: composeFile)

        #expect(dependents["app-db-1"] == ["app-web-1", "app-worker-1"])
        #expect(dependents["app-cache-1"] == ["app-web-1"])
        #expect(dependents["app-web-1"] == [])
    }
}

@Suite("ComposeOrchestrator.ready Tests")
struct ComposeReadyTests {

    private struct DependencyFailed: Error {}

    @Test("waits for the old container's removal as well as the dependencies")
    func waitsForRemoval() async throws {
        let start = Date()
        let removal = Task { _ = try? await Task.sleep(for: .milliseconds(300)) }

        try await ComposeOrchestrator.ready(after: Task {}, removal: removal).value

        #expect(Date().timeIntervalSince(start) >= 0.3)
    }

    @Test("fails when a dependency fails")
    func dependencyFails() async {
        await #expect(throws: DependencyFailed.self) {
            try await ComposeOrchestrator.ready(after: Task { throw DependencyFailed() }, removal: nil).value
        }
    }
}
