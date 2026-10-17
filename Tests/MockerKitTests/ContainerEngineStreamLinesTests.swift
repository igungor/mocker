import Testing
import Foundation
@testable import MockerKit

@Suite("ContainerEngine.streamLines Tests", .serialized)
struct ContainerEngineStreamLinesTests {

    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private let start = Date()
        private var stored: [(String, TimeInterval)] = []

        var lines: [(String, TimeInterval)] { lock.withLock { stored } }

        func add(_ line: String) {
            let at = Date().timeIntervalSince(start)
            lock.withLock { stored.append((line, at)) }
        }
    }

    @Test("passes each line on as it's printed, not when the process exits")
    func linesAsTheyCome() async throws {
        let lines = Lines()

        try await ContainerEngine.streamLines(executable: "/bin/sh", arguments: ["-c", "echo first; sleep 2; echo second"]) { line in
            lines.add(line)
        }
        let got = lines.lines
        #expect(got.map(\.0) == ["first", "second"])
        #expect(got[0].1 < 1.5)
        #expect(got[1].1 >= 1.5)
    }

    @Test("cancelling stops a process that never exits")
    func cancelStopsTheProcess() async throws {
        let lines = Lines()

        let stream = Task {
            try await ContainerEngine.streamLines(executable: "/bin/sh", arguments: ["-c", "while true; do echo tick; sleep 0.1; done"]) { line in
                lines.add(line)
            }
        }
        try await Task.sleep(for: .milliseconds(500))
        stream.cancel()
        _ = await stream.result

        #expect(lines.lines.count >= 1)
    }

    @Test("a streamed process is tracked while it runs, so a signal can stop it")
    func trackedWhileRunning() async throws {
        let before = StreamedProcesses.count

        let stream = Task {
            try await ContainerEngine.streamLines(executable: "/bin/sh", arguments: ["-c", "sleep 1"]) { _ in }
        }
        try await Task.sleep(for: .milliseconds(300))
        #expect(StreamedProcesses.count == before + 1)

        _ = await stream.result
        #expect(StreamedProcesses.count == before)
    }
}
