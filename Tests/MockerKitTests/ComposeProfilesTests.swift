import Foundation
import Testing
@testable import MockerKit

@Suite("Compose profiles")
struct ComposeProfilesTests {
    /// The example from the Compose specification's profiles chapter.
    private static func specExample() throws -> ComposeFile {
        try ComposeFile.parse("""
        services:
          foo:
            image: foo
          bar:
            image: bar
            profiles: [test]
          baz:
            image: baz
            depends_on: [bar]
            profiles: [test]
          zot:
            image: zot
            depends_on: [bar]
            profiles: [debug]
        """)
    }

    private static func enabled(_ active: [String], targets: [String] = []) throws -> [String] {
        try specExample().enablingProfiles(active, targets: targets).services.keys.sorted()
    }

    @Test("Services without profiles are always enabled; others need an active profile")
    func activeProfiles() throws {
        #expect(try Self.enabled([]) == ["foo"])
        #expect(try Self.enabled(["test"]) == ["bar", "baz", "foo"])
        #expect(try Self.enabled(["debug", "test"]) == ["bar", "baz", "foo", "zot"])
        #expect(try Self.enabled(["*"]) == ["bar", "baz", "foo", "zot"])
    }

    @Test("A targeted service activates its own profiles")
    func targetedServiceActivatesItsProfiles() throws {
        #expect(try Self.enabled([], targets: ["bar"]) == ["bar", "baz", "foo"])
        #expect(try Self.enabled([], targets: ["baz"]) == ["bar", "baz", "foo"])
    }

    @Test("Depending on a disabled service is an error")
    func dependencyOnDisabledService() throws {
        #expect(throws: MockerError.self) { try Self.enabled(["debug"]) }
    }

    @Test("--profile flags win over COMPOSE_PROFILES, which beats .env")
    func activeProfileSources() throws {
        let dir = try ComposeTestHelpers.makeProjectDir([.file(".env", "COMPOSE_PROFILES=fromdotenv\n")])
        defer { try? FileManager.default.removeItem(at: dir) }

        #expect(ComposeFile.activeProfiles(flags: ["flag"], projectDir: dir, environment: ["COMPOSE_PROFILES": "env"]) == ["flag"])
        #expect(ComposeFile.activeProfiles(flags: [], projectDir: dir, environment: ["COMPOSE_PROFILES": "a, b"]) == ["a", "b"])
        #expect(ComposeFile.activeProfiles(flags: [], projectDir: dir, environment: [:]) == ["fromdotenv"])
    }

    @Test("A later file's profiles replace the earlier ones")
    func mergeProfiles() throws {
        let base = try ComposeFile.parse("services:\n  tool:\n    image: alpine\n    profiles: [a]\n")
        let overlay = try ComposeFile.parse("services:\n  tool:\n    profiles: [b]\n")

        #expect(ComposeFile.merge([base, overlay]).services["tool"]?.profiles == ["b"])
    }
}
