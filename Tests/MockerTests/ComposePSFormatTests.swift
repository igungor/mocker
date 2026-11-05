import Foundation
import MockerKit
import Testing
@testable import Mocker

@Suite("compose ps --format Tests")
struct ComposePSFormatTests {
    static let now = Date(timeIntervalSince1970: 1_793_879_000)
    static func istanbul(_: Date) -> (abbreviation: String, offset: Int) { ("+03", 10800) }

    static func entry(
        _ name: String, id: String? = nil, image: String = "", command: String = "", project: String = "",
        service: String = "", created: Int, state: String = "", status: String = "",
        publishers: [ComposePSEntry.Publisher] = [], labels: [String: String] = [:]
    ) -> ComposePSEntry {
        ComposePSEntry(
            id: id ?? name, name: name, image: image, command: command, project: project, service: service,
            created: Date(timeIntervalSince1970: TimeInterval(created)), state: state, status: status,
            publishers: publishers, labels: labels
        )
    }

    /// The containers in `ComposePSFormatGolden`, as Docker Compose's `ContainerSummary` had them.
    static let fixtures: [String: [ComposePSEntry]] = {
        let project = "gdprapi-2564206480"
        var zeta = entry(
            "zeta-web-1", id: "sha256:0123456789abcdef0123", image: "nginx:1.27", command: "sh -c \"echo <hi> && sleep 1\"\tx",
            project: "zeta", service: "web", created: 1_793_700_000, state: "exited", status: "Exited",
            publishers: [
                .init(url: "0.0.0.0", targetPort: 8081, publishedPort: 8081, proto: "tcp"),
                .init(url: "0.0.0.0", targetPort: 8080, publishedPort: 8080, proto: "tcp"),
                .init(url: "::", targetPort: 8080, publishedPort: 8080, proto: "tcp"),
                .init(url: "", targetPort: 9000, publishedPort: 0, proto: "udp"),
            ],
            labels: ["b": "2", "a": "1"]
        )
        zeta.names = ["/zeta-web-1"]

        let stack = [
            entry(
                "\(project)-snowflake-1", image: "677516718998.dkr.ecr.us-east-1.amazonaws.com/bigdata/fakesnow:v0.1.0",
                command: "python /snowflake/start.py", project: project, service: "snowflake", created: 1_793_878_900,
                state: "running", status: "Up",
                labels: ["com.mocker.compose.project": project, "com.mocker.compose.service": "snowflake"]
            ),
            entry(
                "\(project)-gdprapi-1", image: "golang:1.26.10-alpine3.23", command: "/gdprapi -config /gdprapi.toml",
                project: project, service: "gdprapi", created: 1_793_878_978, state: "running", status: "Up",
                publishers: [.init(url: "127.0.0.1", targetPort: 8080, publishedPort: 65389, proto: "tcp")],
                labels: ["com.mocker.compose.project": project, "com.mocker.compose.service": "gdprapi"]
            ),
            entry(
                "\(project)-builder-1", image: "golang:1.26.10-alpine3.23", command: "go build -ldflags -w -o gdprapi.linux .",
                project: project, service: "builder", created: 1_793_878_975, state: "exited", status: "Exited"
            ),
            zeta,
        ]

        let ages = [
            0, 1, 2, 59, 60, 119, 120, 3599, 3600, 5399, 5400, 170_640, 172_800, 1_209_599, 1_209_600,
            5_183_999, 5_184_000, 63_071_999, 63_072_000, 94_608_000,
        ]
        let durations = ages.map { entry(String(format: "d%09d", $0), created: 1_793_879_000 - $0) }

        return ["stack": stack, "empty": [], "durations": durations]
    }()

    @Test("renders every format the way Docker Compose does", arguments: ComposePSFormatGolden.cases.indices)
    func matchesDocker(_ index: Int) throws {
        let golden = ComposePSFormatGolden.cases[index]
        let entries = try #require(Self.fixtures[golden.fixture])

        let output = try ComposePSFormat.render(
            format: golden.format, entries: entries, trunc: !golden.noTrunc, now: Self.now, zone: Self.istanbul
        )

        #expect(output == (golden.output.isEmpty ? "" : golden.output + "\n"), "--format \(golden.format)")
    }

    @Test("no --format is the default table")
    func noFormatIsTable() throws {
        let entries = try #require(Self.fixtures["stack"])
        let none = try ComposePSFormat.render(format: nil, entries: entries, trunc: true, now: Self.now, zone: Self.istanbul)
        let table = try ComposePSFormat.render(format: "table", entries: entries, trunc: true, now: Self.now, zone: Self.istanbul)
        #expect(none == table)
    }

    @Test("rejects template actions it can't run instead of printing them", arguments: [
        "{{if .State}}x{{end}}", "{{range .Names}}x{{end}}", "{{printf \"%s\" .Name}}", "{{.}}", "{{len .Name}}",
    ])
    func rejectsUnsupported(_ format: String) throws {
        let entries = try #require(Self.fixtures["stack"])
        #expect(throws: TemplateError.self) {
            try ComposePSFormat.render(format: format, entries: entries, trunc: true, now: Self.now, zone: Self.istanbul)
        }
    }

    @Test("fails on a field containers don't have, as Docker does")
    func unknownField() throws {
        let entries = try #require(Self.fixtures["stack"])
        #expect(throws: TemplateError.self) {
            try ComposePSFormat.render(format: "{{.Nope}}", entries: entries, trunc: true, now: Self.now, zone: Self.istanbul)
        }
    }

    @Test("maps a runtime container to Docker's fields")
    func fromContainerInfo() {
        let container = ContainerInfo(
            id: "p-web-1", name: "p-web-1", image: "nginx", state: .stopped, status: "Exited",
            created: Self.now,
            ports: [
                PortMapping(hostPort: 8443, containerPort: 443),
                PortMapping(hostPort: 51000, containerPort: 80, hostIp: "127.0.0.1"),
            ],
            labels: ["com.mocker.compose.project": "p", "com.mocker.compose.service": "web"]
        )

        let entry = ComposePSEntry(container)

        #expect(entry.state == "exited")
        #expect(entry.project == "p")
        #expect(entry.service == "web")
        #expect(entry.publishers == [
            .init(url: "127.0.0.1", targetPort: 80, publishedPort: 51000, proto: "tcp"),
            .init(url: "0.0.0.0", targetPort: 443, publishedPort: 8443, proto: "tcp"),
        ])
    }

    @Test("Go's tabwriter: a block's width is its widest cell plus 3, at least 10, and the last cell isn't padded")
    func tabWriter() {
        let expected = "a" + String(repeating: " ", count: 13) + "bb" + String(repeating: " ", count: 8) + "c\n"
            + "longer name" + String(repeating: " ", count: 13) + "\n"
        #expect(TabWriter.format("a\tbb\tc\nlonger name\t\t\n") == expected)
    }

    @Test("the local zone is the tz database's abbreviation, as Go prints it")
    func localZone() {
        let zone = ComposePSFormat.localZone(Self.now)
        #expect(!zone.abbreviation.isEmpty)
        #expect(zone.offset == TimeZone.current.secondsFromGMT(for: Self.now))
    }
}
