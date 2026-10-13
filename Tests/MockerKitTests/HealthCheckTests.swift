import Foundation
import Testing
@testable import MockerKit

@Suite("HealthCheck")
struct HealthCheckTests {
    @Test("test: CMD runs as is, CMD-SHELL and a string run through sh -c, NONE disables")
    func commandForms() {
        #expect(HealthCheck.command(from: ["CMD", "mysqladmin", "ping"]) == ["mysqladmin", "ping"])
        #expect(HealthCheck.command(from: ["CMD-SHELL", "curl -f localhost || exit 1"]) == ["sh", "-c", "curl -f localhost || exit 1"])
        #expect(HealthCheck.command(from: "curl -f localhost") == ["sh", "-c", "curl -f localhost"])
        #expect(HealthCheck.command(from: ["NONE"]).isEmpty)
    }

    @Test("Durations like 1s, 1m30s and 500ms; anything else is rejected")
    func durations() {
        #expect(HealthCheck.duration("1s") == 1)
        #expect(HealthCheck.duration("1m30s") == 90)
        #expect(HealthCheck.duration("500ms") == 0.5)
        #expect(HealthCheck.duration("1h") == 3600)
        #expect(HealthCheck.duration("5") == nil)
        #expect(HealthCheck.duration("1s junk") == nil)
    }

    @Test("Parse a healthcheck and the depends_on conditions; unset fields keep Docker's defaults")
    func parseService() throws {
        let compose = try ComposeFile.parse("""
        services:
          db:
            image: mysql:8.4
            healthcheck:
              test: ["CMD", "mysqladmin", "ping"]
              interval: 1s
              retries: 120
          cache:
            image: valkey:8
            healthcheck:
              disable: true
          app:
            image: alpine
            depends_on:
              db:
                condition: service_healthy
              cache:
                condition: service_started
        """)

        let db = try #require(compose.services["db"]?.healthcheck)
        #expect(db == HealthCheck(command: ["mysqladmin", "ping"], interval: 1, timeout: 30, retries: 120, startPeriod: 0))
        #expect(compose.services["cache"]?.healthcheck?.isDisabled == true)
        #expect(compose.services["app"]?.dependsOnConditions == ["db": "service_healthy", "cache": "service_started"])
        #expect(compose.services["app"]?.healthcheck == nil)
    }

    private actor Probes {
        private var results: [Bool]
        private(set) var count = 0

        init(_ results: [Bool]) { self.results = results }

        func next() -> Bool {
            count += 1
            return results.isEmpty ? false : results.removeFirst()
        }
    }

    private func wait(_ check: HealthCheck, _ probes: Probes) async throws -> Bool {
        try await HealthCheck.waitUntilHealthy(check, probe: { await probes.next() }, sleep: { _ in })
    }

    @Test("Healthy as soon as a probe passes")
    func healthyWhenProbePasses() async throws {
        let probes = Probes([false, false, true])

        #expect(try await wait(HealthCheck(command: ["true"], interval: 1, retries: 3), probes))
        #expect(await probes.count == 3)
    }

    @Test("Unhealthy after `retries` failures in a row")
    func unhealthyAfterRetries() async throws {
        let probes = Probes([])

        #expect(try await !wait(HealthCheck(command: ["false"], interval: 1, retries: 3), probes))
        #expect(await probes.count == 3)
    }

    @Test("Failures during start_period don't count")
    func startPeriodFailuresDontCount() async throws {
        let probes = Probes([])

        #expect(try await !wait(HealthCheck(command: ["false"], interval: 1, retries: 3, startPeriod: 2), probes))
        #expect(await probes.count == 5)
    }
}
