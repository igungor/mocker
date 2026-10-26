import Foundation

/// The runtime goes on creating a container after the mocker that asked for it exits, so
/// a `compose up` that Ctrl-C ended at once could leave one that appeared after the next
/// `down` had listed the project.
public final class ContainerCreations: @unchecked Sendable {
    public static let shared = ContainerCreations()

    private let lock = NSLock()
    private var running: [UUID: String] = [:]
    private var interrupted = false
    private var held: [CheckedContinuation<Void, Never>] = []
    private var sources: [DispatchSourceSignal] = []

    var names: Set<String> { lock.withLock { Set(running.values) } }

    /// SIGINT, SIGTERM and SIGHUP are handled even when mocker started with them ignored, as
    /// a shell starts a script's background jobs. Docker Compose handles them too.
    public func endingOnSignal<T>(
        listed: @escaping @Sendable () async -> Set<String>?,
        _ up: () async throws -> T
    ) async throws -> T {
        endOnSignal(listed: listed)
        return try await holdingErrorsOnInterrupt(up)
    }

    /// Runs `up`, and after `interrupt` holds the caller instead of throwing: a runtime call
    /// the signal killed fails `up`, and that error must not end mocker before the runtime
    /// lists the containers it is creating.
    func holdingErrorsOnInterrupt<T>(_ up: () async throws -> T) async throws -> T {
        do {
            return try await up()
        } catch {
            if lock.withLock({ interrupted }) { await hold() }
            throw error
        }
    }

    func track<T: Sendable>(_ name: String, _ create: @Sendable () async throws -> T) async throws -> T {
        let id = UUID()
        let admitted = lock.withLock {
            guard !interrupted else { return false }
            running[id] = name
            return true
        }
        guard admitted else { await hold() }

        defer { lock.withLock { running[id] = nil } }
        return try await create()
    }

    func interrupt() -> Bool {
        lock.withLock {
            defer { interrupted = true }
            return !interrupted
        }
    }

    func waitUntilListed(
        _ listed: @Sendable () async -> Set<String>?,
        timeout: Duration = .seconds(10),
        pollInterval: Duration = .milliseconds(50)
    ) async -> Set<String> {
        let deadline = ContinuousClock.now + timeout
        var seen: Set<String> = []

        while true {
            let pending = names
            if pending.isEmpty { return [] }

            if let listing = await listed() { seen = listing }
            if pending.isSubset(of: seen) { return [] }

            guard ContinuousClock.now < deadline else { return pending.subtracting(seen) }
            try? await Task.sleep(for: pollInterval)
        }
    }

    private func hold() async -> Never {
        await withCheckedContinuation { continuation in
            lock.withLock { held.append(continuation) }
        }
        fatalError("a held caller was resumed")
    }

    private func endOnSignal(listed: @escaping @Sendable () async -> Set<String>?) {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
            source.setEventHandler { [self] in
                guard interrupt() else { Self.end(by: sig) }

                Task {
                    let missing = await waitUntilListed(listed)
                    if !missing.isEmpty {
                        let names = missing.sorted().joined(separator: ", ")
                        FileHandle.standardError.write(Data(
                            "WARNING: the runtime hasn't listed \(names) yet, so the next `down` or `up` may not find it\n".utf8))
                    }
                    Self.end(by: sig)
                }
            }
            source.resume()
            lock.withLock { sources.append(source) }
        }
    }

    /// A shell running a script stops it only when the program Ctrl-C ended was killed by
    /// the signal, not when it exited with 130. The signal is unblocked first, since the
    /// thread this runs on can block it, and `raise` would then return.
    private static func end(by sig: Int32) -> Never {
        signal(sig, SIG_DFL)
        var unblocked = sigset_t()
        sigemptyset(&unblocked)
        sigaddset(&unblocked, sig)
        pthread_sigmask(SIG_UNBLOCK, &unblocked, nil)
        raise(sig)
        exit(128 + sig)
    }
}
