import Foundation
import Testing
@testable import MockerKit

@Suite("ContainerCreations Tests")
struct ContainerCreationsTests {

    private actor Flag {
        var value = false

        func set() {
            value = true
        }
    }

    private actor Listing {
        var calls = 0
        let names: Set<String>

        init(_ names: Set<String>) {
            self.names = names
        }

        func list() -> Set<String>? {
            calls += 1
            switch calls {
            case 1: return nil
            case 2: return []
            default: return names
            }
        }
    }

    @Test("runs a creation and returns its result")
    func runs() async throws {
        let creations = ContainerCreations()

        let result = try await creations.track("app-db-1") { 42 }

        #expect(result == 42)
        #expect(creations.names.isEmpty)
    }

    @Test("only the first interrupt is the first")
    func firstInterrupt() {
        let creations = ContainerCreations()

        #expect(creations.interrupt())
        #expect(!creations.interrupt())
    }

    @Test("after an interrupt, a creation never starts")
    func heldAfterInterrupt() async throws {
        let creations = ContainerCreations()
        let started = Flag()
        _ = creations.interrupt()

        _ = Task { try await creations.track("app-db-1") { await started.set() } }
        try await Task.sleep(for: .milliseconds(100))

        #expect(await started.value == false)
        #expect(creations.names.isEmpty)
    }

    @Test("waits until the runtime lists the containers being created, not until they boot")
    func waitsUntilListed() async throws {
        let creations = ContainerCreations()
        let listing = Listing(["app-db-1", "other"])
        let finished = Flag()

        let creation = Task {
            try await creations.track("app-db-1") {
                try await Task.sleep(for: .seconds(5))
                await finished.set()
            }
        }
        while creations.names.isEmpty { await Task.yield() }

        _ = creations.interrupt()
        let missing = await creations.waitUntilListed({ await listing.list() }, pollInterval: .milliseconds(10))

        #expect(missing.isEmpty)
        #expect(await listing.calls == 3)
        #expect(await finished.value == false)
        creation.cancel()
    }

    @Test("gives up after the timeout, and names the containers the runtime didn't list")
    func givesUp() async throws {
        let creations = ContainerCreations()

        let creation = Task {
            try await creations.track("app-db-1") { try await Task.sleep(for: .seconds(5)) }
        }
        while creations.names.isEmpty { await Task.yield() }

        _ = creations.interrupt()
        let missing = await creations.waitUntilListed(
            { ["other"] }, timeout: .milliseconds(50), pollInterval: .milliseconds(10))

        #expect(missing == ["app-db-1"])
        creation.cancel()
    }

    @Test("returns once no creation is left, though the runtime never listed it")
    func returnsWhenNoneLeft() async throws {
        let creations = ContainerCreations()

        let creation = Task {
            try await creations.track("app-db-1") { try await Task.sleep(for: .milliseconds(100)) }
        }
        while creations.names.isEmpty { await Task.yield() }

        _ = creations.interrupt()
        let missing = await creations.waitUntilListed({ [] }, pollInterval: .milliseconds(10))

        #expect(missing.isEmpty)
        #expect(creations.names.isEmpty)
        try await creation.value
    }

    @Test("an error without an interrupt is thrown")
    func errorThrown() async {
        let creations = ContainerCreations()

        await #expect(throws: CancellationError.self) {
            try await creations.holdingErrorsOnInterrupt { () -> Int in throw CancellationError() }
        }
    }

    @Test("an error after an interrupt holds the caller instead of ending mocker")
    func errorHeldAfterInterrupt() async throws {
        let creations = ContainerCreations()
        let returned = Flag()
        _ = creations.interrupt()

        _ = Task {
            _ = try? await creations.holdingErrorsOnInterrupt { () -> Int in throw CancellationError() }
            await returned.set()
        }
        try await Task.sleep(for: .milliseconds(100))

        #expect(await returned.value == false)
    }
}
