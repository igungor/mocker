import Testing
@testable import MockerKit

@Suite("ContainerEngine logs Tests")
struct ContainerEngineLogsTests {

    @Test("passes the tail to the runtime as -n")
    func tailArgument() {
        #expect(ContainerEngine.logsArguments(name: "app-db-1", follow: false, tail: 30) == ["logs", "app-db-1", "-n", "30"])
        #expect(ContainerEngine.logsArguments(name: "app-db-1", follow: true, tail: 5) == ["logs", "app-db-1", "-f", "-n", "5"])
    }

    @Test("asks for every line without a tail")
    func noTail() {
        #expect(ContainerEngine.logsArguments(name: "app-db-1", follow: false, tail: nil) == ["logs", "app-db-1"])
    }

    @Test("reads Docker's --tail values")
    func tailValues() throws {
        #expect(try ContainerEngine.tailLines(nil) == nil)
        #expect(try ContainerEngine.tailLines("all") == nil)
        #expect(try ContainerEngine.tailLines("30") == 30)
        #expect(try ContainerEngine.tailLines("0") == 0)
        #expect(throws: MockerError.self) { try ContainerEngine.tailLines("ten") }
        #expect(throws: MockerError.self) { try ContainerEngine.tailLines("-1") }
    }
}
