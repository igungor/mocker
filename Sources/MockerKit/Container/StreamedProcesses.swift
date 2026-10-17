import Foundation

/// The runtime processes mocker streams output from, such as a followed `container
/// logs`. A signal that ends mocker, like SIGTERM from `timeout` or an agent's tool,
/// isn't sent to them, so without this they'd keep running with no reader.
public enum StreamedProcesses {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var pids: Set<pid_t> = []
    nonisolated(unsafe) private static var sources: [DispatchSourceSignal] = []

    static var count: Int { lock.withLock { pids.count } }

    static func add(_ pid: pid_t) {
        _ = lock.withLock { pids.insert(pid) }
    }

    static func remove(_ pid: pid_t) {
        _ = lock.withLock { pids.remove(pid) }
    }

    /// On SIGINT, SIGTERM or SIGHUP, stop every streamed process, then exit as the
    /// signal would have.
    public static func stopOnSignal() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler {
                for pid in lock.withLock({ pids }) {
                    kill(pid, SIGTERM)
                }
                exit(128 + sig)
            }
            source.resume()
            lock.withLock { sources.append(source) }
        }
    }
}
