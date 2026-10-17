import Foundation
import Testing
@testable import MockerKit

@Suite("ComposeFile environment without a value Tests")
struct ComposeEnvironmentInheritTests {

    private let host = ["FROM_HOST": "on"]

    @Test("a map entry without a value comes from mocker's environment, or is left out")
    func mapEntryFromYAML() throws {
        let compose = try ComposeFile.parse("""
        services:
          app:
            image: alpine
            environment:
              PATH:
              MOCKER_TEST_NEVER_SET:
              SET: value
        """)
        let env = try #require(compose.services["app"]).environment

        #expect(env["PATH"] == ProcessInfo.processInfo.environment["PATH"])
        #expect(env["MOCKER_TEST_NEVER_SET"] == nil)
        #expect(env["SET"] == "value")
    }

    @Test("a map entry without a value takes the host's value")
    func mapNullFromHost() {
        #expect(ComposeService.parseEnvironment(["FROM_HOST": NSNull(), "SET": "value"], hostEnvironment: host) == ["FROM_HOST": "on", "SET": "value"])
        #expect(ComposeService.parseEnvironment(["MISSING": NSNull()], hostEnvironment: host).isEmpty)
    }

    @Test("a bare list entry takes the host's value, or is left out")
    func listBare() {
        #expect(ComposeService.parseEnvironment(["FROM_HOST", "MISSING", "SET=value"], hostEnvironment: host) == ["FROM_HOST": "on", "SET": "value"])
    }

    @Test("an empty list value stays an empty string")
    func listEmptyValue() {
        #expect(ComposeService.parseEnvironment(["EMPTY="], hostEnvironment: host) == ["EMPTY": ""])
    }
}
