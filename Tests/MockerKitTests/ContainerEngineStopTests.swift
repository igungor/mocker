import Foundation
import Testing
@testable import MockerKit

@Suite("ContainerEngine.stopWithKill Tests")
struct ContainerEngineStopTests {

    private actor Runtime {
        var signals: [String] = []
        var checks = 0
        let killSucceeds: Bool
        let runningChecks: Int

        init(killSucceeds: Bool = true, runningChecks: Int = .max) {
            self.killSucceeds = killSucceeds
            self.runningChecks = runningChecks
        }

        func kill(_ signal: String) -> Bool {
            signals.append(signal)
            return killSucceeds
        }

        func isRunning() -> Bool {
            checks += 1
            return checks <= runningChecks
        }
    }

    private func stop(_ runtime: Runtime, signal: String = "SIGTERM", timeout: Duration) async throws -> Bool {
        try await ContainerEngine.stopWithKill(
            signal: signal,
            timeout: timeout,
            pollInterval: .milliseconds(10),
            kill: { await runtime.kill($0) },
            isRunning: { await runtime.isRunning() }
        )
    }

    @Test("with no timeout, sends SIGKILL at once")
    func noTimeout() async throws {
        let runtime = Runtime()

        let stopped = try await stop(runtime, timeout: .zero)

        #expect(stopped)
        #expect(await runtime.signals == ["SIGKILL"])
    }

    @Test("sends the stop signal, and no SIGKILL to a container that stops in time")
    func stopsInTime() async throws {
        let runtime = Runtime(runningChecks: 2)

        let stopped = try await stop(runtime, signal: "SIGQUIT", timeout: .seconds(5))

        #expect(stopped)
        #expect(await runtime.signals == ["SIGQUIT"])
    }

    @Test("sends SIGKILL to a container still running at the timeout")
    func killsAtTimeout() async throws {
        let runtime = Runtime()
        let start = ContinuousClock.now

        let stopped = try await stop(runtime, timeout: .milliseconds(100))

        #expect(stopped)
        #expect(await runtime.signals == ["SIGTERM", "SIGKILL"])
        #expect(ContinuousClock.now - start >= .milliseconds(100))
    }

    @Test("a container that exited before it was signalled counts as stopped")
    func alreadyExited() async throws {
        let runtime = Runtime(killSucceeds: false, runningChecks: 0)

        let stopped = try await stop(runtime, timeout: .seconds(5))

        #expect(stopped)
        #expect(await runtime.signals == ["SIGTERM", "SIGKILL"])
    }

    @Test("a container SIGKILL can't reach and that still runs isn't stopped")
    func killFails() async throws {
        let runtime = Runtime(killSucceeds: false)

        let stopped = try await stop(runtime, timeout: .zero)

        #expect(!stopped)
    }

    @Test("a container counts as running until the runtime reports it stopped")
    func inspectState() {
        let entry = { (state: String) in ["status": ["state": state]] as [String: Any] }

        #expect(ContainerEngine.isRunning(inspect: entry("running")))
        #expect(ContainerEngine.isRunning(inspect: entry("stopping")))
        #expect(!ContainerEngine.isRunning(inspect: entry("stopped")))
    }

    @Test("the stop signal comes from the image's configuration, when it sets one")
    func inspectStopSignal() {
        #expect(ContainerEngine.stopSignal(inspect: ["configuration": ["stopSignal": "SIGQUIT"]]) == "SIGQUIT")
        #expect(ContainerEngine.stopSignal(inspect: ["configuration": ["id": "web"]]) == nil)
    }
}
