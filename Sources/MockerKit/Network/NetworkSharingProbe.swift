import Foundation

/// InternetSharing, the root daemon behind vmnet networks, waits with no timeout for its
/// `rtadvd` to exit on every network change, so an rtadvd stuck in a send hangs every
/// network create and container start. Neither can be inspected without root, but a stuck
/// rtadvd leaves unread router solicitations in its socket's receive queue, and a hung
/// InternetSharing logs nothing.
public struct NetworkSharingProbe: Sendable {
    private let runner: ProcessRunning

    public init(runner: ProcessRunning = RealProcessRunner()) {
        self.runner = runner
    }

    public func stuckRouterAdvertiser() async -> Int32? {
        guard let pid = await routerAdvertiserPID(),
              let first = await receiveQueue(of: pid), first > 0 else {
            return nil
        }

        // A healthy rtadvd drains its queue within milliseconds; one that holds as much a
        // second later is not reading at all.
        try? await Task.sleep(for: .seconds(1))
        guard let second = await receiveQueue(of: pid), second >= first else {
            return nil
        }

        return pid
    }

    public func isSilent(since start: Date) async -> Bool {
        let arguments = [
            "show", "--start", Self.logTimestamp(start), "--style", "compact",
            "--predicate", "process == \"InternetSharing\"",
        ]
        guard let result = try? await runner.run(executable: "/usr/bin/log", arguments: arguments),
              result.1 == 0 else {
            return false
        }

        return Self.logLines(result.0) == 0
    }

    private func routerAdvertiserPID() async -> Int32? {
        guard let sharing = await firstPID(["-x", "InternetSharing"]) else { return nil }

        return await firstPID(["-P", String(sharing), "rtadvd"])
    }

    public static func hangMessage(rtadvd pid: Int32?) -> String {
        guard let pid else {
            return "macOS InternetSharing has stopped answering, so networks cannot be created and "
                + "containers cannot start. Recover without a reboot: sudo kill -9 $(pgrep -x InternetSharing)"
        }

        return "macOS InternetSharing is blocked waiting for its rtadvd to exit, so networks "
            + "cannot be created and containers cannot start. Recover without a reboot: sudo kill -9 \(pid)"
    }

    private func firstPID(_ arguments: [String]) async -> Int32? {
        guard let result = try? await runner.run(executable: "/usr/bin/pgrep", arguments: arguments),
              result.1 == 0 else {
            return nil
        }

        return result.0
            .split(whereSeparator: \.isNewline)
            .first
            .flatMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func receiveQueue(of pid: Int32) async -> Int? {
        guard let result = try? await runner.run(executable: "/usr/sbin/netstat", arguments: ["-anv", "-f", "inet6"]),
              result.1 == 0 else {
            return nil
        }

        return Self.receiveQueue(netstat: result.0, pid: pid)
    }

    /// Recv-Q of the ICMPv6 socket that `pid` owns, from `netstat -anv -f inet6`.
    static func receiveQueue(netstat output: String, pid: Int32) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ")
            guard fields.first == "icm6", fields.contains(where: { $0 == "rtadvd:\(pid)" }), fields.count > 1 else {
                continue
            }

            return Int(fields[1])
        }

        return nil
    }

    static func logLines(_ output: String) -> Int {
        output
            .split(whereSeparator: \.isNewline)
            .filter { !$0.hasPrefix("Timestamp") }
            .count
    }

    static func logTimestamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        return formatter.string(from: date)
    }
}
