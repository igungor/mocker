import Foundation
import Testing
@testable import MockerKit

@Suite("Compose multi-file merge")
struct ComposeMergeTests {
    @Test("merges each field the way compose-go does", arguments: ComposeMergeGolden.cases.indices)
    func matchesComposeGo(index: Int) throws {
        let golden = ComposeMergeGolden.cases[index]

        let merged = ComposeFile.merge(try golden.files.map { try ComposeFile.parse($0) })
        let rendered = try Self.render(merged)

        #expect(rendered == golden.merged + "\n", "\(golden.name)")
    }

    @Test("A later file's short depends_on is compose-go's service_started")
    func shortDependsOn() throws {
        let compose = try ComposeFile.parse("services:\n  app:\n    image: alpine\n    depends_on: [db]\n  db:\n    image: postgres\n")

        #expect(compose.services["app"]?.dependsOnConditions == ["db": "service_started"])
    }

    @Test("Port keys fill in compose-go's defaults")
    func portKeys() {
        #expect(ComposeService.portKey("8080:80") == "0.0.0.0:8080:80/tcp")
        #expect(ComposeService.portKey("0.0.0.0:8080:80/TCP") == "0.0.0.0:8080:80/tcp")
        #expect(ComposeService.portKey("127.0.0.1::80") == "127.0.0.1::80/tcp")
        #expect(ComposeService.portKey("[::1]:8080:80/udp") == "::1:8080:80/udp")
        #expect(ComposeService.portKey("80") == "0.0.0.0::80/tcp")
    }

    /// The merged services as `ComposeMergeGolden` renders compose-go's: one line per
    /// field set, in the form compose-go keeps it.
    static func render(_ file: ComposeFile) throws -> String {
        var out = ""
        for (name, service) in file.services.sorted(by: { $0.key < $1.key }) {
            out += name + "\n"
            func line(_ key: String, _ values: [String]) {
                if !values.isEmpty { out += "  \(key): " + values.joined(separator: " | ") + "\n" }
            }

            if let image = service.image { line("image", [image]) }
            if let build = service.build {
                let args = build.args.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                line("build", [
                    "context=\(build.context) dockerfile=\(build.dockerfile ?? "Dockerfile") "
                        + "target=\(build.target ?? "-") args=[\(args)]",
                ])
            }
            line("command", service.command)
            line("entrypoint", service.entrypoint)
            line("environment", service.environment.map { "\($0.key)=\($0.value)" }.sorted())
            line("labels", service.labels.map { "\($0.key)=\($0.value)" }.sorted())

            line("ports", try service.ports.map { spec in
                let port = try PortMapping.parse(spec)
                let published = port.hostPort == 0 ? "" : String(port.hostPort)
                return "\(port.hostIp ?? ""):\(published):\(port.containerPort)/\(port.portProtocol.rawValue)"
            })
            line("volumes", try service.volumes.map { spec in
                // compose-go cleans the target; mocker hands it to the runtime as written.
                let mount = try VolumeMount.parse(spec)
                let target = URL(fileURLWithPath: mount.destination).standardized.path
                let volume = mount.source.isEmpty ? target : "\(mount.source):\(target)"
                return mount.readOnly ? volume + ":ro" : volume
            })

            let networks = service.networks.isEmpty ? ["default"] : service.networks
            line("networks", networks.map { "\($0)(\((service.networkAliases[$0] ?? []).joined(separator: ",")))" }.sorted())
            line("depends_on", service.dependsOn.map { "\($0)=\(service.dependsOnConditions[$0] ?? "service_started")" }.sorted())

            // compose-go fills in a secret's default target, and leaves a config's empty.
            line("configs", service.configs.map { reference($0, target: $0.target ?? "") })
            line("secrets", service.secrets.map { reference($0, target: $0.target ?? "/run/secrets/\($0.source)") })
            line("profiles", service.profiles)
            line("tmpfs", service.tmpfs)

            if let check = service.healthcheck {
                line("healthcheck", [
                    "test=[\(check.command.joined(separator: " "))] interval=\(seconds(check.interval)) "
                        + "timeout=\(seconds(check.timeout)) retries=\(check.retries) "
                        + "start_period=\(seconds(check.startPeriod))",
                ])
            }
        }
        return out
    }

    private static func reference(_ reference: ComposeFileReference, target: String) -> String {
        "\(reference.source):\(target):\(reference.mode.map { String($0, radix: 8) } ?? "-")"
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        interval == interval.rounded() ? String(Int(interval)) : String(interval)
    }
}
