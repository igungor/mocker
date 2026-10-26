import Foundation
import Testing
@testable import MockerKit

@Suite("ContainerEngine.deleteInRuntime Tests")
struct ContainerEngineDeleteTests {

    private actor Runtime {
        var calls: [[String]] = []
        let result: (String, Int32)

        init(_ output: String = "", exitCode: Int32 = 0) {
            result = (output, exitCode)
        }

        func run(_ arguments: [String]) -> (String, Int32) {
            calls.append(arguments)
            return result
        }
    }

    private func delete(_ runtime: Runtime, force: Bool) async throws {
        try await ContainerEngine.deleteInRuntime("app-db-1", force: force, run: { await runtime.run($0) })
    }

    @Test("with force, asks the runtime to delete a container even if it is running")
    func force() async throws {
        let runtime = Runtime()

        try await delete(runtime, force: true)

        #expect(await runtime.calls == [["delete", "--force", "app-db-1"]])
    }

    @Test("without force, asks for a plain delete")
    func plain() async throws {
        let runtime = Runtime()

        try await delete(runtime, force: false)

        #expect(await runtime.calls == [["delete", "app-db-1"]])
    }

    @Test("a container the runtime doesn't have is already gone")
    func notFound() async throws {
        let runtime = Runtime(
            #"Error: internalError: "failed to delete container" (cause: "notFound: "container with ID app-db-1 not found"")"#,
            exitCode: 1)

        try await delete(runtime, force: true)
    }

    @Test("throws the runtime's error when it refuses, so the container isn't forgotten")
    func refused() async throws {
        let runtime = Runtime(
            #"Error: internalError: "failed to delete container" (cause: "invalidState: "container app-db-1 is running and can not be deleted"")"#,
            exitCode: 1)

        let error = await #expect(throws: MockerError.self) { try await delete(runtime, force: false) }

        guard case .operationFailed(let message) = error else {
            Issue.record("unexpected error: \(String(describing: error))")
            return
        }
        #expect(message.hasPrefix("failed to remove container app-db-1: "))
        #expect(message.contains("is running and can not be deleted"))
    }
}
