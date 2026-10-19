import Foundation

/// The `container start --attach` process of a foreground run.
///
/// Spawned with `posix_spawn` rather than `Process`, which can't start a child in its
/// own process group.
enum AttachedProcess {
    static func spawn(
        _ executable: String,
        _ arguments: [String],
        ownProcessGroup: Bool,
        inheritStdin: Bool
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        // mocker ignores the signals it relays; the child must not inherit that.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        for signal in SignalRelay.signals {
            sigaddset(&defaults, signal)
        }
        posix_spawnattr_setsigdefault(&attributes, &defaults)

        var flags = Int16(POSIX_SPAWN_SETSIGDEF)
        if ownProcessGroup {
            flags |= Int16(POSIX_SPAWN_SETPGROUP)
            posix_spawnattr_setpgroup(&attributes, 0)
        }
        posix_spawnattr_setflags(&attributes, flags)

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        if !inheritStdin {
            posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0)
        }

        let argv = ([executable] + arguments).map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }

        var pid: pid_t = 0
        let result = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
        guard result == 0 else {
            throw MockerError.operationFailed("failed to start \(executable): \(String(cString: strerror(result)))")
        }
        return pid
    }

    /// Wait for `pid` to exit and return its exit code.
    static func wait(_ pid: pid_t) async -> Int32 {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                var status: Int32 = 0
                while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
                continuation.resume(returning: exitCode(fromWaitStatus: status))
            }
        }
    }

    /// A `waitpid` status as a shell reports it: the exit code, or 128 plus the signal
    /// that killed the process.
    static func exitCode(fromWaitStatus status: Int32) -> Int32 {
        let signal = status & 0x7f
        return signal == 0 ? (status >> 8) & 0xff : 128 + signal
    }

    /// Run a command to completion and drop its output.
    static func runQuietly(_ executable: String, _ arguments: [String]) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        process.waitUntilExit()
    }
}

/// Handles SIGINT, SIGTERM and SIGHUP while a foreground run is attached, instead of
/// letting them end mocker.
final class SignalRelay: @unchecked Sendable {
    static let signals: [Int32] = [SIGINT, SIGTERM, SIGHUP]

    private var sources: [DispatchSourceSignal] = []

    init(handler: @escaping @Sendable (Int32) -> Void) {
        for signal in Self.signals {
            Darwin.signal(signal, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signal, queue: .global())
            source.setEventHandler { handler(signal) }
            source.resume()
            sources.append(source)
        }
    }

    /// Stop handling the signals and give them their default action back.
    func cancel() {
        for source in sources {
            source.cancel()
        }
        sources = []
        for signal in Self.signals {
            Darwin.signal(signal, SIG_DFL)
        }
    }

    /// The name `container kill --signal` takes for one of `signals`.
    static func name(of signal: Int32) -> String {
        switch signal {
        case SIGINT: "SIGINT"
        case SIGTERM: "SIGTERM"
        case SIGHUP: "SIGHUP"
        default: String(signal)
        }
    }
}
