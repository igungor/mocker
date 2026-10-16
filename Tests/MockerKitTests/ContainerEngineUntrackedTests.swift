import Testing
import Foundation
@testable import MockerKit

@Suite("ContainerEngine.untrackedComposeContainers Tests")
struct ContainerEngineUntrackedTests {

    private let lsJSON = """
    [
      {
        "configuration": {
          "id": "app-db-1",
          "image": {"reference": "docker.io/library/mysql:8.4"},
          "labels": {"com.mocker.compose.project": "app", "com.mocker.compose.service": "db"},
          "publishedPorts": []
        },
        "status": {"state": "running", "networks": [{"ipv4Address": "192.168.65.2/24"}]}
      },
      {
        "configuration": {
          "id": "app-web-1",
          "image": {"reference": "docker.io/library/nginx:1.27"},
          "labels": {"com.mocker.compose.project": "app", "com.mocker.compose.service": "web"},
          "publishedPorts": [
            {"containerPort": 80, "count": 1, "hostAddress": "127.0.0.1", "hostPort": 18089, "proto": "tcp"},
            {"containerPort": 9000, "count": 2, "hostAddress": "0.0.0.0", "hostPort": 19000, "proto": "udp"}
          ]
        },
        "status": {"state": "stopped", "networks": []}
      },
      {
        "configuration": {
          "id": "scratch",
          "image": {"reference": "docker.io/library/alpine:3.22"},
          "labels": {},
          "publishedPorts": []
        },
        "status": {"state": "running", "networks": []}
      }
    ]
    """

    @Test("returns compose containers missing from the store, and only those")
    func onlyUntrackedComposeContainers() {
        let untracked = ContainerEngine.untrackedComposeContainers(lsJSON: lsJSON, known: ["app-db-1"])

        #expect(untracked.map(\.name) == ["app-web-1"])
    }

    @Test("keeps the runtime's labels, image, state and published ports")
    func keepsRuntimeDetails() throws {
        let web = try #require(ContainerEngine.untrackedComposeContainers(lsJSON: lsJSON, known: []).first { $0.name == "app-web-1" })

        #expect(web.id == "app-web-1")
        #expect(web.image == "docker.io/library/nginx:1.27")
        #expect(web.state == .stopped)
        #expect(web.labels["com.mocker.compose.service"] == "web")
        #expect(web.ports.map(\.description) == ["127.0.0.1:18089:80/tcp", "19000:9000/udp", "19001:9001/udp"])
    }

    @Test("reads the running state and address")
    func runningState() throws {
        let db = try #require(ContainerEngine.untrackedComposeContainers(lsJSON: lsJSON, known: []).first { $0.name == "app-db-1" })

        #expect(db.state == .running)
        #expect(db.networkAddress == "192.168.65.2")
    }

    @Test("returns nothing for output that isn't a JSON list")
    func invalidOutput() {
        #expect(ContainerEngine.untrackedComposeContainers(lsJSON: "ID IMAGE", known: []).isEmpty)
        #expect(ContainerEngine.untrackedComposeContainers(lsJSON: "", known: []).isEmpty)
    }
}
