import Testing
import Foundation
@testable import MockerKit

@Suite("NetworkSharingProbe")
struct NetworkSharingProbeTests {
    /// Real `netstat -anv -f inet6` output from a Mac with InternetSharing hung.
    private let stuckNetstat = """
    Active Internet connections (including servers)
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
    icm6    2852      0  *.*                    *.*                                        5940           88    8192    8192           rtadvd:84500  00080 00000000 0000000000b01e7d 20000000 00000800      2      0 000002
    icm6       0      0  *.*                    *.*                                       22828          120    8192    8192          configd:353    00180 00000000 0000000000aa1b4b 20008000 00000800      1      0 000002
    """

    private let healthyNetstat = """
    Proto Recv-Q Send-Q  Local Address          Foreign Address        (state)          rxbytes      txbytes  rhiwat  shiwat          process:pid    state  options           gencnt    flags   flags1 usecnt rtncnt fltrs
    icm6       0      0  *.*                    *.*                                        1416          352    8192    8192           rtadvd:84500  00080 00000000 0000000000bde25d 20000000 00000800      2      0 000002
    """

    private let silentLog = "Timestamp               Ty Process[PID:TID]\n"

    @Test("Reads the receive queue of rtadvd's socket, not another process's")
    func parsesReceiveQueue() {
        #expect(NetworkSharingProbe.receiveQueue(netstat: stuckNetstat, pid: 84500) == 2852)
        #expect(NetworkSharingProbe.receiveQueue(netstat: healthyNetstat, pid: 84500) == 0)
        #expect(NetworkSharingProbe.receiveQueue(netstat: stuckNetstat, pid: 353) == nil)
        #expect(NetworkSharingProbe.receiveQueue(netstat: "", pid: 84500) == nil)
    }

    @Test("A log with only its header has no entries")
    func countsLogEntries() {
        #expect(NetworkSharingProbe.logLines(silentLog) == 0)
        #expect(NetworkSharingProbe.logLines(silentLog
            + "2026-11-04 10:26:34.765 Df InternetSharing[78187:5c77c1] [com.apple.xpc:connection] invalidated\n") == 1)
    }

    @Test("An rtadvd whose receive queue stays full is reported as stuck")
    func reportsStuckRouterAdvertiser() async {
        let runner = MockProcessRunner(responses: [
            ("78187\n", 0), ("84500\n", 0), (stuckNetstat, 0), (stuckNetstat, 0),
        ])

        let pid = await NetworkSharingProbe(runner: runner).stuckRouterAdvertiser()

        #expect(pid == 84500)
        let calls = await runner.calls
        #expect(calls.map(\.arguments) == [
            ["-x", "InternetSharing"], ["-P", "78187", "rtadvd"], ["-anv", "-f", "inet6"], ["-anv", "-f", "inet6"],
        ])
    }

    @Test("An rtadvd with an empty receive queue is healthy, checked once")
    func healthyRouterAdvertiser() async {
        let runner = MockProcessRunner(responses: [("78187\n", 0), ("84500\n", 0), (healthyNetstat, 0)])

        let pid = await NetworkSharingProbe(runner: runner).stuckRouterAdvertiser()

        #expect(pid == nil)
        #expect(await runner.calls.count == 3)
    }

    @Test("No rtadvd running means nothing to report")
    func noRouterAdvertiser() async {
        let runner = MockProcessRunner(responses: [("78187\n", 0), ("", 1)])

        #expect(await NetworkSharingProbe(runner: runner).stuckRouterAdvertiser() == nil)
    }

    @Test("The message names the stuck rtadvd to kill, or InternetSharing when rtadvd is not the cause")
    func hangMessage() {
        #expect(NetworkSharingProbe.hangMessage(rtadvd: 84500).hasSuffix("sudo kill -9 84500"))
        #expect(NetworkSharingProbe.hangMessage(rtadvd: nil).hasSuffix("sudo kill -9 $(pgrep -x InternetSharing)"))
    }

    @Test("A network create that outlives its patience while InternetSharing is silent fails with the fix")
    func hungNetworkCreateFails() async throws {
        let runner = ScriptedRunner { [stuckNetstat, silentLog] executable, arguments in
            switch executable {
            case "/usr/bin/container":
                try? await Task.sleep(for: .seconds(30))
                return ("", 0)
            case "/usr/bin/log":
                return (silentLog, 0)
            case "/usr/sbin/netstat":
                return (stuckNetstat, 0)
            default:
                return (arguments.contains("rtadvd") ? "84500\n" : "78187\n", 0)
            }
        }
        let manager = try NetworkManager(runner: runner, cli: "/usr/bin/container", patience: .milliseconds(100))

        let started = ContinuousClock.now
        let error = await #expect(throws: MockerError.self) {
            _ = try await manager.create(name: "shared")
        }

        #expect(error?.localizedDescription.contains("sudo kill -9 84500") == true)
        #expect(ContinuousClock.now - started < .seconds(5))
    }

    @Test("A slow network create keeps waiting while InternetSharing is still logging")
    func slowNetworkCreateWaits() async throws {
        let listJSON = """
        [{"status":{"ipv4Gateway":"192.168.65.1","ipv4Subnet":"192.168.65.0/24"},
          "id":"shared","state":"running","config":{"mode":"nat","labels":{},"id":"shared"}}]
        """
        let runner = ScriptedRunner { executable, arguments in
            switch (executable, arguments.first) {
            case ("/usr/bin/container", "network") where arguments.dropFirst().first == "create":
                try? await Task.sleep(for: .milliseconds(300))
                return ("", 0)
            case ("/usr/bin/container", _):
                return (listJSON, 0)
            default:
                return ("Timestamp\n2026-11-04 11:03:38.172 Df InternetSharing[78187:5c77c1] started\n", 0)
            }
        }
        let manager = try NetworkManager(runner: runner, cli: "/usr/bin/container", patience: .milliseconds(100))

        let network = try await manager.create(name: "shared")

        #expect(network.name == "shared")
    }
}

private struct ScriptedRunner: ProcessRunning {
    let respond: @Sendable (String, [String]) async -> (String, Int32)

    init(_ respond: @escaping @Sendable (String, [String]) async -> (String, Int32)) {
        self.respond = respond
    }

    func run(executable: String, arguments: [String]) async throws -> (String, Int32) {
        await respond(executable, arguments)
    }
}
