import Foundation
import Testing
@testable import MockerKit

@Suite("Compose configs")
struct ComposeConfigsTests {
    @Test("Parses top-level configs and both service forms")
    func parse() throws {
        let file = try ComposeFile.parse("""
        services:
          app:
            image: alpine
            configs:
              - plain
              - source: inline
                target: etc/inline.conf
                mode: "0440"
              - source: env
                mode: 288
        configs:
          plain:
            file: ./app.conf
          inline:
            content: hello
          env:
            environment: SETTING
          shared:
            external: true
        """)

        #expect(file.configs["plain"] == ComposeConfigDefinition(file: "./app.conf"))
        #expect(file.configs["inline"] == ComposeConfigDefinition(content: "hello"))
        #expect(file.configs["env"] == ComposeConfigDefinition(environment: "SETTING"))
        #expect(file.configs["shared"]?.external == true)

        let references = try #require(file.services["app"]?.configs)
        #expect(references == [
            ComposeConfigReference(source: "plain"),
            ComposeConfigReference(source: "inline", target: "etc/inline.conf", mode: 0o440),
            ComposeConfigReference(source: "env", mode: 0o440),
        ])
        #expect(references.map(\.containerPath) == ["/plain", "/etc/inline.conf", "/env"])
    }

    @Test("Names follow compose-go: name:, the key when external, <project>_<key> otherwise")
    func runtimeName() {
        #expect(ComposeConfigDefinition(content: "x").runtimeName(key: "app", projectName: "demo") == "demo_app")
        #expect(ComposeConfigDefinition(external: true).runtimeName(key: "app", projectName: "demo") == "app")
        #expect(ComposeConfigDefinition(content: "x", customName: "custom").runtimeName(key: "app", projectName: "demo") == "custom")
    }

    @Test("environment: takes its content from .env and the shell, like interpolation")
    func environmentContent() throws {
        let dir = try ComposeTestHelpers.makeProjectDir([
            .file(".env", "FROM_DOTENV=dotenv value\n"),
            .file("compose.yaml", """
            services:
              app:
                image: alpine
            configs:
              dotenv:
                environment: FROM_DOTENV
              unset:
                environment: MOCKER_TEST_UNSET_VARIABLE
            """),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = try ComposeFile.load(from: dir.appendingPathComponent("compose.yaml").path, projectDir: dir)

        #expect(file.configs["dotenv"]?.content == "dotenv value")
        #expect(file.configs["unset"]?.content == nil)
    }

    @Test("Later files add configs and replace a service's list")
    func merge() throws {
        let base = try ComposeFile.parse("""
        services:
          app:
            image: alpine
            configs: [a]
        configs:
          a:
            content: one
        """)
        let overlay = try ComposeFile.parse("""
        services:
          app:
            configs: [b]
        configs:
          b:
            content: two
        """)

        let merged = ComposeFile.merge([base, overlay])

        #expect(merged.configs.keys.sorted() == ["a", "b"])
        #expect(merged.services["app"]?.configs == [ComposeConfigReference(source: "b")])
    }

    @Test("A config list change changes the service hash")
    func hash() throws {
        let plain = try #require(try ComposeFile.parse("services:\n  app:\n    image: alpine\n").services["app"])
        var withConfig = plain
        withConfig.configs = [ComposeConfigReference(source: "a")]

        #expect(ComposeService.hash(of: plain) != ComposeService.hash(of: withConfig))
    }
}
