import Foundation
import Testing
@testable import MockerKit

@Suite("Compose secrets")
struct ComposeSecretsTests {
    @Test("Parses secrets like configs, under /run/secrets by default")
    func parse() throws {
        let file = try ComposeFile.parse("""
        services:
          app:
            image: alpine
            secrets:
              - password
              - source: token
                target: api_token
              - source: token
                target: /etc/app/token
        secrets:
          password:
            file: ./password.txt
          token:
            environment: TOKEN
        """)

        #expect(file.secrets["password"] == ComposeFileObject(file: "./password.txt"))
        #expect(file.secrets["token"] == ComposeFileObject(environment: "TOKEN"))
        #expect(file.configs.isEmpty)

        let references = try #require(file.services["app"]?.secrets)
        #expect(references.map { $0.containerPath(in: "/run/secrets/") } == [
            "/run/secrets/password", "/run/secrets/api_token", "/etc/app/token",
        ])
    }

    @Test("environment: secrets resolve from .env, and an include's file is anchored to it")
    func load() throws {
        let dir = try ComposeTestHelpers.makeProjectDir([
            .file(".env", "TOKEN=from dotenv\n"),
            .file("compose.yaml", """
            include: [sub/compose.yaml]
            services:
              app:
                image: alpine
            secrets:
              token:
                environment: TOKEN
            """),
            .file("sub/compose.yaml", """
            services:
              worker:
                image: alpine
            secrets:
              key:
                file: ./key.pem
            """),
        ])
        defer { try? FileManager.default.removeItem(at: dir) }

        let file = try ComposeFile.load(from: dir.appendingPathComponent("compose.yaml").path, projectDir: dir)

        #expect(file.secrets["token"]?.content == "from dotenv")
        #expect(file.secrets["key"]?.file == dir.appendingPathComponent("sub/key.pem").standardized.path)
    }

    @Test("Later files add secrets and replace a service's list; the list is in the hash")
    func mergeAndHash() throws {
        let base = try ComposeFile.parse("services:\n  app:\n    image: alpine\n    secrets: [a]\nsecrets:\n  a:\n    file: a\n")
        let overlay = try ComposeFile.parse("services:\n  app:\n    secrets: [b]\nsecrets:\n  b:\n    file: b\n")

        let merged = ComposeFile.merge([base, overlay])

        #expect(merged.secrets.keys.sorted() == ["a", "b"])
        #expect(merged.services["app"]?.secrets == [ComposeFileReference(source: "b")])

        let app = try #require(merged.services["app"])
        var without = app
        without.secrets = []
        #expect(ComposeService.hash(of: app) != ComposeService.hash(of: without))
    }
}
