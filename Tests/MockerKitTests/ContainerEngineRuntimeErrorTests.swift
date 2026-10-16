import Testing
@testable import MockerKit

@Suite("ContainerEngine.runtimeError Tests")
struct ContainerEngineRuntimeErrorTests {

    @Test("drops the progress lines and the runtime's own Error prefix")
    func dropsProgress() {
        let output = """
        [0/6] [0s]
        [0/6] [0s]
        Error: container with id app-db-1 already exists

        """

        #expect(ContainerEngine.runtimeError(output) == "container with id app-db-1 already exists")
    }

    @Test("drops progress lines that name a step")
    func dropsNamedSteps() {
        let output = """
        [1/6] Fetching image [0s]
        [5/6] Unpacking init image [0s]
        Error: invalid publish host port range: 1
        """

        #expect(ContainerEngine.runtimeError(output) == "invalid publish host port range: 1")
    }

    @Test("keeps every line that isn't progress")
    func keepsOtherLines() {
        let output = "Error: failed to bootstrap\ncause: no space left on device"

        #expect(ContainerEngine.runtimeError(output) == "failed to bootstrap\ncause: no space left on device")
    }

    @Test("is empty when there is only progress")
    func onlyProgress() {
        #expect(ContainerEngine.runtimeError("[0/6] [0s]\n[1/6] Fetching image [0s]\n").isEmpty)
    }
}
