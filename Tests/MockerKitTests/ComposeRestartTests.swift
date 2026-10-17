import Foundation
import Testing
@testable import MockerKit

@Suite("ComposeOrchestrator.restartTargets Tests")
struct ComposeRestartTests {

    private func container(_ service: String, project: String = "app") -> ContainerInfo {
        ContainerInfo(
            id: "\(project)-\(service)-1", name: "\(project)-\(service)-1", image: "alpine", state: .running,
            status: "Up", created: Date(), labels: ["com.mocker.compose.project": project, "com.mocker.compose.service": service]
        )
    }

    @Test("restarts every service's container in the order services start in")
    func everyServiceInOrder() {
        let targets = ComposeOrchestrator.restartTargets(
            [container("web"), container("db"), container("cache")],
            service: nil, order: ["db", "cache", "web"], projectName: "app"
        )

        #expect(targets.map(\.name) == ["app-db-1", "app-cache-1", "app-web-1"])
    }

    @Test("restarts only the named service's container")
    func oneService() {
        let targets = ComposeOrchestrator.restartTargets(
            [container("web"), container("webhook"), container("db")],
            service: "web", order: ["db", "web", "webhook"], projectName: "app"
        )

        #expect(targets.map(\.name) == ["app-web-1"])
    }

    @Test("leaves out services without a container, and other projects' containers")
    func existingOnly() {
        let targets = ComposeOrchestrator.restartTargets(
            [container("db"), container("web", project: "other")],
            service: nil, order: ["db", "web"], projectName: "app"
        )

        #expect(targets.map(\.name) == ["app-db-1"])
    }
}
