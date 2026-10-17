import Testing
@testable import MockerKit

@Suite("ComposeOrchestrator.logPrefixes Tests")
struct ComposeLogPrefixTests {

    @Test("drops the project and pads every name to the longest, as Docker Compose does")
    func paddedServiceNames() {
        let prefixes = ComposeOrchestrator.logPrefixes(["app-db-1", "app-segmentation-1"], projectName: "app")

        #expect(prefixes["app-db-1"] == "db-1           | ")
        #expect(prefixes["app-segmentation-1"] == "segmentation-1 | ")
    }

    @Test("keeps a name that doesn't start with the project")
    func otherNames() {
        #expect(ComposeOrchestrator.logPrefixes(["custom"], projectName: "app")["custom"] == "custom | ")
    }

    @Test("has no prefixes without containers")
    func noContainers() {
        #expect(ComposeOrchestrator.logPrefixes([], projectName: "app").isEmpty)
    }
}
