import Foundation

/// A service's `healthcheck:`. `compose up` runs it with `container exec` while a
/// dependent service waits for it with `depends_on` `condition: service_healthy`.
public struct HealthCheck: Sendable, Equatable {
    // What the file sets, nil where it leaves a key out: a later file overrides only the
    // keys it sets, as compose-go merges a healthcheck as a mapping.
    var test: [String]?
    var disable: Bool?
    var declaredInterval: TimeInterval?
    var declaredTimeout: TimeInterval?
    var declaredRetries: Int?
    var declaredStartPeriod: TimeInterval?

    init(
        command: [String]?,
        interval: TimeInterval? = nil,
        timeout: TimeInterval? = nil,
        retries: Int? = nil,
        startPeriod: TimeInterval? = nil
    ) {
        test = command
        declaredInterval = interval
        declaredTimeout = timeout
        declaredRetries = retries
        declaredStartPeriod = startPeriod
    }

    /// The command to run, in exec form. Empty when the check is disabled.
    public var command: [String] { disable == true ? [] : test ?? [] }

    // Docker's defaults where the files leave a key out.
    public var interval: TimeInterval {
        get { declaredInterval ?? 30 }
        set { declaredInterval = newValue }
    }
    public var timeout: TimeInterval {
        get { declaredTimeout ?? 30 }
        set { declaredTimeout = newValue }
    }
    public var retries: Int {
        get { declaredRetries ?? 3 }
        set { declaredRetries = newValue }
    }
    public var startPeriod: TimeInterval {
        get { declaredStartPeriod ?? 0 }
        set { declaredStartPeriod = newValue }
    }

    public var isDisabled: Bool { command.isEmpty }

    /// Parse a `healthcheck:` mapping.
    static func parse(_ value: Any?) -> HealthCheck? {
        guard let dict = value as? [String: Any] else { return nil }

        var check = HealthCheck(
            command: dict["test"].map { Self.command(from: $0) },
            interval: duration(dict["interval"]),
            timeout: duration(dict["timeout"]),
            retries: (dict["retries"] as? Int).flatMap { $0 > 0 ? $0 : nil },
            startPeriod: duration(dict["start_period"])
        )
        check.disable = dict["disable"] as? Bool
        return check
    }

    func merged(with other: HealthCheck) -> HealthCheck {
        var merged = HealthCheck(
            command: other.test ?? test,
            interval: other.declaredInterval ?? declaredInterval,
            timeout: other.declaredTimeout ?? declaredTimeout,
            retries: other.declaredRetries ?? declaredRetries,
            startPeriod: other.declaredStartPeriod ?? declaredStartPeriod
        )
        merged.disable = other.disable ?? disable
        return merged
    }

    /// `test:` in exec form: `[CMD, args...]` runs as is, `[CMD-SHELL, command]` and a
    /// plain string run through `sh -c`, and `[NONE]` disables the check.
    static func command(from test: Any?) -> [String] {
        if let shell = test as? String { return ["sh", "-c", shell] }
        guard let parts = (test as? [Any])?.map({ "\($0)" }), let kind = parts.first else { return [] }

        switch kind {
        case "CMD": return Array(parts.dropFirst())
        case "CMD-SHELL": return ["sh", "-c", parts.dropFirst().joined(separator: " ")]
        default: return []
        }
    }

    /// A Compose duration such as `1s`, `1m30s` or `500ms`, in seconds.
    static func duration(_ value: Any?) -> TimeInterval? {
        guard let text = value as? String, !text.isEmpty else { return nil }

        let units: [String: TimeInterval] = ["h": 3600, "m": 60, "s": 1, "ms": 0.001, "us": 0.000_001, "ns": 0.000_000_001]
        guard let regex = try? NSRegularExpression(pattern: #"(\d+(?:\.\d+)?)(ms|us|ns|h|m|s)"#) else { return nil }
        let matches = regex.matches(in: text, range: NSRange(text.startIndex..., in: text))

        var seconds: TimeInterval = 0
        var covered = 0
        for match in matches {
            guard match.range.location == covered,
                  let number = Range(match.range(at: 1), in: text).flatMap({ TimeInterval(text[$0]) }),
                  let unit = Range(match.range(at: 2), in: text).flatMap({ units[String(text[$0])] })
            else { return nil }
            seconds += number * unit
            covered += match.range.length
        }
        return covered == (text as NSString).length ? seconds : nil
    }

    /// Docker's health status from one probe, since mocker keeps none between commands:
    /// `starting` until Docker would have counted `retries` failures after the start period.
    public func status(passed: Bool, age: TimeInterval) -> String {
        if passed { return "healthy" }
        return age < startPeriod + interval * Double(retries) ? "starting" : "unhealthy"
    }

    enum Outcome: Equatable {
        case healthy, unhealthy, exited
    }

    /// Run `probe` every `interval` until it passes. Failures during `startPeriod`
    /// don't count; after it, `retries` failures in a row mean the service is unhealthy.
    /// A container that isn't running after a failed probe has exited, so it can't
    /// become healthy: Docker Compose reports that at once instead of waiting out the
    /// retries.
    static func waitUntilHealthy(
        _ check: HealthCheck,
        probe: @Sendable () async -> Bool,
        isRunning: @Sendable () async -> Bool = { true },
        sleep: @Sendable (TimeInterval) async throws -> Void
    ) async throws -> Outcome {
        // An already healthy container, as most are on a later `up --wait`, passes
        // without waiting out an interval: Docker answers from the status it keeps,
        // and mocker keeps none. A failure here doesn't count, so an unhealthy
        // container still gets Docker's `retries` probes, `interval` apart.
        if await probe() { return .healthy }
        if await !isRunning() { return .exited }

        var elapsed: TimeInterval = 0
        var failures = 0
        while true {
            try await sleep(check.interval)
            elapsed += check.interval
            if await probe() { return .healthy }
            if await !isRunning() { return .exited }

            if elapsed > check.startPeriod {
                failures += 1
                if failures >= check.retries { return .unhealthy }
            }
        }
    }
}
